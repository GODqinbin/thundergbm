//
// Created by jiashuai on 18-1-18.
//
#include <thundergbm/tree.h>
#include <thundergbm/dataset.h>
#include <thrust/reduce.h>
#include "thrust/adjacent_difference.h"
#include <thrust/execution_policy.h>
#include <thrust/system/cuda/detail/par.h>
#include <thrust/sequence.h>
#include <thrust/sort.h>
#include <thrust/binary_search.h>
#include <thrust/device_vector.h>
#include "gtest/gtest.h"
#include "thundergbm/util/device_lambda.cuh"

class UpdaterTest : public ::testing::Test {
public:
    InsStat stats;
    vector<Tree> trees;
    SparseColumns columns;
    unsigned int n_instances;

    int depth = 6;
    int n_trees = 30;
    float_type min_child_weight = 1;
    float_type lambda = 1;
    float_type gamma = 1;
    float_type rt_eps = 1e-6;
    string path = DATASET_DIR "abalone";

    void SetUp() override {
//#ifdef NDEBUG
        el::Loggers::reconfigureAllLoggers(el::Level::Debug, el::ConfigurationType::Enabled, "false");
//#endif
        DataSet dataSet;
        dataSet.load_from_file(path);
        n_instances = dataSet.n_instances();
        columns.init(dataSet);
        trees.resize(n_trees);
        stats.init(n_instances);
        int round = 0;
        {
            TIMED_SCOPE(timerObj, "construct tree");
            for (Tree &tree:trees) {
                init_stats(dataSet);
                init_tree(tree);
                float_type rmse = 0;
                const GHPair *gh_data = stats.gh_pair.host_data();
                for (int i = 0; i < stats.n_instances; ++i) {
                    rmse += gh_data[i].g * gh_data[i].g;
                }
                LOG(INFO) << "rmse = " << sqrt(rmse / n_instances);
                int i;
                for (i = 0; i < depth; ++i) {
                    if (!find_split(tree, i)) break;
                }
                //annotate leaf nodes in last level
                {
                    TIMED_SCOPE(timerObj, "leaf nodes last level");
                    Tree::TreeNode *last_level_nodes_data = tree.nodes.device_data() + int(pow(2, depth) - 1);
                    int n_nodes_last_level = static_cast<int>(pow(2, depth));

                    device_loop(n_nodes_last_level, [=]__device__(int i) {
                        last_level_nodes_data[i].is_leaf = true;
                    });
                }
                prune(tree);
                tree.reorder_nid();
//                LOG(INFO) << string_format("\nbooster[%d]", round) << tree.to_string(depth);
                //compute weights of leaf nodes and predict
                {
                    TIMED_SCOPE(timerObj, "predict");
                    float_type *y_predict_data = stats.y_predict.device_data();
                    const int *nid_data = stats.nid.device_data();
                    const Tree::TreeNode *nodes_data = tree.nodes.device_data();
                    device_loop(n_instances, [=]__device__(int i) {
                        int nid = nid_data[i];
                        while (nid != 0 && (nodes_data[nid].is_pruned)) nid = (nid - 1) / 2;
                        y_predict_data[i] += nodes_data[nid].base_weight;
                    });
                }
                round++;
            }
        }
    }

    void init_stats(DataSet &dataSet) {
        SyncArray<float_type> y(dataSet.y().size());
        y.copy_from(dataSet.y().data(), y.size());
        float_type *y_data = y.device_data();
        GHPair *gh_pair_data = stats.gh_pair.device_data();
        int *nid_data = stats.nid.device_data();
        float_type *stats_y_data = stats.y.device_data();
        float_type *stats_yp_data = stats.y_predict.device_data();
        LOG(DEBUG) << stats.y_predict;
        LOG(INFO) << "initializing instance statistics";
        device_loop(n_instances, [=] __device__(int i) {
            nid_data[i] = 0;
            stats_y_data[i] = y_data[i];
            gh_pair_data[i].g = stats_yp_data[i] - y_data[i];
            gh_pair_data[i].h = 1;
        });
        LOG(DEBUG) << "gradient/hessian " << stats.gh_pair;
        LOG(DEBUG) << "node id " << stats.nid;
    }

    void init_tree(Tree &tree) {
        tree.init(depth);
        //init root node
        Tree::TreeNode &root_node = tree.nodes.host_data()[0];
        root_node.sum_gh_pair = thrust::reduce(thrust::cuda::par, stats.gh_pair.device_data(),
                                               stats.gh_pair.device_end());
        root_node.is_valid = true;
        root_node.calc_weight(lambda);
        LOG(DEBUG) << root_node.sum_gh_pair;
    }


    vector<int> leaf_child_count;

    int try_prune_leaf(Tree::TreeNode *nodes_data, int nid, int np) {
        if (nid == 0) return np;// is root
        int p_nid = (nid - 1) / 2;
        leaf_child_count[p_nid]++;
        if (leaf_child_count[p_nid] >= 2 && nodes_data[p_nid].gain < gamma) {
            //do pruning
            //delete two children
            CHECK(nodes_data[p_nid * 2 + 1].is_leaf);
            CHECK(nodes_data[p_nid * 2 + 2].is_leaf);
            nodes_data[p_nid * 2 + 1].is_pruned = true;
            nodes_data[p_nid * 2 + 2].is_pruned = true;
            //make parent to leaf
            nodes_data[p_nid].is_leaf = true;
            return try_prune_leaf(nodes_data, p_nid, np + 2);
        } else return np;
    }

    void prune(Tree &tree) {
        leaf_child_count.clear();
        leaf_child_count.resize(tree.nodes.size(), 0);
        Tree::TreeNode *nodes_data = tree.nodes.host_data();
        int n_pruned = 0;
        for (int i = 0; i < tree.nodes.size(); ++i) {
            if (nodes_data[i].is_leaf && nodes_data[i].is_valid) {
                n_pruned = try_prune_leaf(nodes_data, i, n_pruned);
            }
        }
        LOG(INFO) << string_format("%d nodes are pruned", n_pruned);
    }

    //return true if there are splittable nodes
    bool find_split(Tree &tree, int level) {
        int n_max_nodes_in_level = static_cast<int>(pow(2, level));
        int nid_offset = static_cast<int>(pow(2, level) - 1);
        int n_column = columns.n_column;
        int n_partition = n_column * n_max_nodes_in_level;
        int nnz = columns.nnz;
        int n_block = std::min(( nnz / n_column  - 1 ) / 256 + 1, 32 * 56);
        LOG(INFO)<<"#block = "<<n_block;

        {
            using namespace thrust;
            SyncArray<int> fid2pid(nnz);
            {
                TIMED_SCOPE(timerObj, "fid2pid");
                int *fid2pid_data = fid2pid.device_data();
                int *nid_data = stats.nid.device_data();
                int *iid_data = columns.csc_row_ind.device_data();

                device_lambda_2d_sparse(n_column, columns.csc_col_ptr.device_data(),
                                        [=]__device__(int col_id, int fid) {
                                            //feature id -> instance id -> node id
                                            int nid = nid_data[iid_data[fid]];
                                            int pid;
                                            //if this node is leaf node, move it to the end
                                            if (nid < nid_offset) pid = INT_MAX;//todo negative
                                            else pid = (nid - nid_offset) * n_column + col_id;
                                            fid2pid_data[fid] = pid;
                                        }, n_block);
                LOG(DEBUG) << "fid2pid " << fid2pid;
                cudaDeviceSynchronize();
            }


            //gather g/h pairs and do prefix sum
            SyncArray<GHPair> gh_prefix_sum(nnz);
            SyncArray<float_type> node_val(nnz);
            {
                //get feature id mapping for partition, new -> old
                SyncArray<int> fid_new2old(nnz);
                {
                    TIMED_SCOPE(timerObj, "fid_new2old");
                    sequence(cuda::par, fid_new2old.device_data(), fid_new2old.device_end(), 0);
                    stable_sort_by_key(cuda::par, fid2pid.device_data(), fid2pid.device_end(), fid_new2old.device_data(),
                                       thrust::less<int>());
                    LOG(DEBUG) << "sorted fid2pid " << fid2pid;
//                LOG(DEBUG) << "fid_new2old " << fid_new2old;
                    cudaDeviceSynchronize();
                }
                GHPair *original_gh_data = stats.gh_pair.device_data();
                GHPair *gh_prefix_sum_data = gh_prefix_sum.device_data();
                int *fid_new2old_data = fid_new2old.device_data();
                int *iid_data = columns.csc_row_ind.device_data();
                float_type *csc_val_data = columns.csc_val.device_data();
                float_type *node_val_data = node_val.device_data();

                {
                    TIMED_SCOPE(timerObj, "gathering");
                    device_loop(nnz, [=]__device__(int new_fid) {
                        //new feature id -> old feature id
                        int old_fid = fid_new2old_data[new_fid];
                        //old feature id -> instance id
                        int iid = iid_data[old_fid];
                        //gathering
                        gh_prefix_sum_data[new_fid] = original_gh_data[iid];
                        node_val_data[new_fid] = csc_val_data[old_fid];
                    });
                    LOG(DEBUG) << "gathered g/h " << gh_prefix_sum;
                    cudaDeviceSynchronize();
                }

                {
                    TIMED_SCOPE(timerObj, "prefix sum");
                    inclusive_scan_by_key(cuda::par, fid2pid.device_data(), fid2pid.device_end(),
                                          gh_prefix_sum.device_data(),
                                          gh_prefix_sum.device_data());
                    LOG(DEBUG) << "prefix sum " << gh_prefix_sum;
                    cudaDeviceSynchronize();
                }
            }

            //find node start position
            SyncArray<int> pid_ptr(n_max_nodes_in_level * n_column + 1);
            {
                TIMED_SCOPE(timerObj, "node start position");
                counting_iterator<int> search_begin(0);

                upper_bound(cuda::par, fid2pid.device_data(), fid2pid.device_end(), search_begin,
                            search_begin + n_partition, pid_ptr.device_data() + 1);
                LOG(DEBUG) << pid_ptr;
                cudaDeviceSynchronize();
            }

            //calculate gain of each split
            SyncArray<float_type> gain(nnz);
            SyncArray<bool> default_right(nnz);
            {
                TIMED_SCOPE(timerObj, "calculate gain");
                auto compute_gain = []__device__(GHPair father, GHPair lch, GHPair rch, float_type min_child_weight,
                                                 float_type lambda) -> float_type {
                    if (lch.h >= min_child_weight && rch.h >= min_child_weight)
                        return (lch.g * lch.g) / (lch.h + lambda) + (rch.g * rch.g) / (rch.h + lambda) -
                               (father.g * father.g) / (father.h + lambda);
                    else
                        return 0;
                };

                int *pid_ptr_data = pid_ptr.device_data();
                int *fid2pid_data = fid2pid.device_data();
                const Tree::TreeNode *nodes_data = tree.nodes.device_data();
                float_type *f_val_data = columns.csc_val.device_data();
//                int *fid_new2old_data = fid_new2old.device_data();
                float_type *node_val_data = node_val.device_data();
                GHPair *gh_prefix_sum_data = gh_prefix_sum.device_data();
                float_type *gain_data = gain.device_data();
                bool *default_right_data = default_right.device_data();
                //for lambda expression
                float_type mcw = min_child_weight;
                float_type l = lambda;
                float_type rt_eps = this->rt_eps;

                device_loop(nnz, [=]__device__(int fid) {
                    int pid = fid2pid_data[fid];//partition id
                    int nid = pid / n_column + nid_offset;
                    if (pid == INT_MAX) return;
                    int begin = pid_ptr_data[pid];//partition begin position
                    int end = pid_ptr_data[pid + 1] - 1;//partition end position
                    GHPair father_gh = nodes_data[nid].sum_gh_pair;
                    GHPair missing_gh = father_gh - gh_prefix_sum_data[end];
                    if (fid == begin) {
                        gain_data[fid] = compute_gain(father_gh, father_gh - missing_gh, missing_gh, mcw, l);
                    } else if (fabsf(node_val_data[fid - 1] - node_val_data[fid]) >
                               2 * rt_eps) {
                        GHPair rch_gh = gh_prefix_sum_data[fid - 1];
                        float_type max_gain = compute_gain(father_gh, father_gh - rch_gh, rch_gh, mcw, l);
                        if (missing_gh.h > 1) {
                            rch_gh = rch_gh + missing_gh;
                            float_type temp_gain = compute_gain(father_gh, father_gh - rch_gh, rch_gh, mcw, l);
                            if (temp_gain > 0 && temp_gain - max_gain > 0.1) {
                                max_gain = temp_gain;
                                default_right_data[fid] = true;
                            }
                        }
                        gain_data[fid] = max_gain;
                    };
//                    if (nid == 57 && pid % n_column == 1)
//                        printf("fid = %d, gain = %f, fval = %f\n", fid, gain_data[fid],
//                               f_val_data[fid_new2old_data[fid]]);
                });
                LOG(DEBUG) << "gain = " << gain;
                cudaDeviceSynchronize();
            }

            //get best gain and the index of best gain for each feature and each node
            {
                TIMED_SCOPE(timerObj, "get best gain");
                typedef tuple<int, float_type> arg_max_t;
                auto arg_max = []__device__(const arg_max_t &a, const arg_max_t &b) {
                    if (fabsf(get<1>(a) - get<1>(b)) < 1e-6)
                        return get<0>(a) < get<0>(b) ? a : b;
                    else
                        return get<1>(a) > get<1>(b) ? a : b;
                };
                auto in_same_node = [=]__device__(const int a, const int b) {
                    return (a / n_column) == (b / n_column);
                };
                //todo not to use device_vector
                device_vector<int> reduced_pid(n_max_nodes_in_level);
                device_vector<arg_max_t> best_split(n_max_nodes_in_level);
                device_ptr<float_type> gain_data = device_pointer_cast(gain.device_data());
                device_ptr<int> fid2pid_data = device_pointer_cast(fid2pid.device_data());

                //reduce to get best split of each node for this feature
                int n_nodes_in_level = reduce_by_key(fid2pid_data, fid2pid_data + nnz,
                                                     make_zip_iterator(
                                                             make_tuple(counting_iterator<int>(0), gain_data)),
                                                     reduced_pid.begin(), best_split.begin(),
                                                     in_same_node, arg_max).first - reduced_pid.begin();

                //update global best split for each node
                device_ptr<arg_max_t> best_split_data = best_split.data();
                device_ptr<int> reduced_pid_data = reduced_pid.data();
                const int *pid_ptr_data = pid_ptr.device_data();
                Tree::TreeNode *nodes_data = tree.nodes.device_data();
                GHPair *gh_prefix_sum_data = gh_prefix_sum.device_data();
//                int *fid_new2old_data = fid_new2old.device_data();
                float_type *node_val_data = node_val.device_data();
                float_type *f_val_data = columns.csc_val.device_data();
                bool *default_right_data = default_right.device_data();
                float_type rt_eps = this->rt_eps;
                float_type lambda = this->lambda;

                device_loop(n_nodes_in_level, [=]__device__(int i) {
                    arg_max_t bst = best_split_data[i];
                    float_type best_split_gain = get<1>(bst);
                    if (best_split_gain > rt_eps) {
                        //do split
                        int split_index = get<0>(bst);
                        int pid = fid2pid_data[split_index];
                        if (pid == INT_MAX) return;
                        int nid0 = pid / n_column;
                        int nid = nid0 + nid_offset;
                        Tree::TreeNode &node = nodes_data[nid];
                        node.gain = best_split_gain;

                        Tree::TreeNode &lch = nodes_data[nid * 2 + 1];//left child
                        Tree::TreeNode &rch = nodes_data[nid * 2 + 2];//right child
                        lch.is_valid = true;
                        rch.is_valid = true;
                        node.col_id = pid % n_column;
                        int begin = pid_ptr_data[pid];
                        int end = pid_ptr_data[pid + 1] - 1;
                        GHPair missing_gh = node.sum_gh_pair - gh_prefix_sum_data[end];
                        if (split_index == begin) {
                            node.split_value = node_val_data[end] -
                                               fabsf(node_val_data[split_index]) - rt_eps;
                            lch.sum_gh_pair = missing_gh;
                            rch.sum_gh_pair = gh_prefix_sum_data[end];
                        } else {
                            node.split_value = (node_val_data[split_index] +
                                                node_val_data[split_index - 1]) * 0.5f;
                            rch.sum_gh_pair = gh_prefix_sum_data[split_index - 1];
                            if (default_right_data[split_index]) {
                                rch.sum_gh_pair = rch.sum_gh_pair + missing_gh;
                                node.default_right = true;
                            }
                            lch.sum_gh_pair = node.sum_gh_pair - rch.sum_gh_pair;
                        }
                        lch.calc_weight(lambda);
                        rch.calc_weight(lambda);
//                        printf("pid = %d, pid %% ncol = %d, ncol = %d, nid = %d, best_split_gain = %f, col_id = %d, split_value = %f, split_index = %d\n",
//                               pid, pid % n_column, n_column, nid, best_split_gain, node.col_id, node.split_value,
//                               split_index);
                    } else {
                        //set leaf
                        int pid2 = reduced_pid_data[i];
                        if (pid2 == INT_MAX) return;
                        int nid = pid2 / n_column + nid_offset;
                        Tree::TreeNode &node = nodes_data[nid];
                        node.is_leaf = true;
                        nodes_data[nid * 2 + 1].is_valid = false;
                        nodes_data[nid * 2 + 2].is_valid = false;
                    }
                });
                cudaDeviceSynchronize();
            }
        }

        SyncArray<bool> has_splittable(1);
        //set new node id for each instance
        {
            TIMED_SCOPE(timerObj, "get new node id");
            int *nid_data = stats.nid.device_data();
            const int *iid_data = columns.csc_row_ind.device_data();
            const Tree::TreeNode *nodes_data = tree.nodes.device_data();
            const int *col_ptr_data = columns.csc_col_ptr.device_data();
            const float_type *f_val_data = columns.csc_val.device_data();
            has_splittable.host_data()[0] = false;
            bool *h_s_data = has_splittable.device_data();

            device_lambda_2d_sparse(n_column, col_ptr_data,
                                    [=]__device__(int col_id, int fid) {
                                        //feature id -> instance id
                                        int iid = iid_data[fid];
                                        //instance id -> node id
                                        int nid = nid_data[iid];
                                        //node id -> node
                                        const Tree::TreeNode &node = nodes_data[nid];
                                        //if the node splits on this feature
                                        if (node.splittable() && node.col_id == col_id) {
                                            h_s_data[0] = true;
                                            //node goes to next level
                                            nid *= 2;
                                            if (f_val_data[fid] < node.split_value)
                                                //goes to left child
                                                nid += 1;
                                            else
                                                //right child
                                                nid += 2;
                                            nid_data[iid] = nid;
                                        }
                                    }, n_block);

            //processing missing value
            device_loop(n_instances, [=]__device__(int iid) {
                int nid = nid_data[iid];
                //if the instance is not on leaf node and not goes down
                if (nodes_data[nid].splittable() && nid < nid_offset + n_max_nodes_in_level) {
                    //let the instance goes down
                    nid_data[iid] *= 2;
                    if (nodes_data[nid].default_right)
                        nid_data[iid] += 2;
                    else
                        nid_data[iid] += 1;
                }
            });
            cudaDeviceSynchronize();
        }
        LOG(DEBUG) << "new nid = " << stats.nid;
        return has_splittable.host_data()[0];
    }

};


TEST_F(UpdaterTest, test) {
}