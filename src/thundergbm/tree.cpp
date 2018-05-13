//
// Created by jiashuai on 18-1-18.
//
#include "thundergbm/tree.h"

Tree::Tree(int depth) {
    init(depth);
}

void Tree::init(int depth) {
    int n_max_nodes = static_cast<int>(pow(2, depth + 1) - 1);
    nodes.resize(n_max_nodes);
    TreeNode *node_data = nodes.host_data();
    for (int i = 0; i < n_max_nodes; ++i) {
        node_data[i].nid = i;
        node_data[i].col_id = -1;
        node_data[i].is_valid = false;
        node_data[i].is_leaf = false;
    }
}

string Tree::to_string(int depth) const {
    string s("\n");
    preorder_traversal(0, depth, 0, s);
    return s;
}

void Tree::preorder_traversal(int nid, int max_depth, int depth, string &s) const {
    const TreeNode &node = nodes.host_data()[nid];
    if (node.is_valid && !node.is_pruned)
        s = s + string(static_cast<unsigned long>(depth), '\t') +
            (node.is_leaf ?
             string_format("%d:leaf=%.6g\n", node.nid, node.base_weight) :
             string_format("%d:[f%d<%.6g], weight=%f, gain=%f, dr=%d\n", node.nid, node.col_id + 1, node.split_value,
                           node.base_weight, node.gain, node.default_right));
    if (depth < max_depth) {
        preorder_traversal(nid * 2 + 1, max_depth, depth + 1, s);
        preorder_traversal(nid * 2 + 2, max_depth, depth + 1, s);
    }
}

std::ostream &operator<<(std::ostream &os, const Tree::TreeNode &node) {
    os << string_format("\nnid:%d,l:%d,col_id:%d,f:%f,gain:%.2f,r:%d,w:%f,", node.nid, node.is_leaf,
                        node.col_id, node.split_value, node.gain, node.default_right, node.base_weight);
    os << "g/h:" << node.sum_gh_pair;
    return os;
}

void Tree::reorder_nid() {
    int nid = 0;
    Tree::TreeNode *nodes_data = nodes.host_data();
    for (int i = 0; i < nodes.size(); ++i) {
        if (nodes_data[i].is_valid && !nodes_data[i].is_pruned) {
            nodes_data[i].nid = nid;
            nid++;
        }
    }
}