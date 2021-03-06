/*
 * BagManager.cu
 *
 *  Created on: 8 Aug 2016
 *      Author: Zeyi Wen
 *		@brief: 
 */

#include "BagManager.h"
#include "BagBuilder.h"
#include "../Memory/gpuMemManager.h"
#include "../../SharedUtility/KernelConf.h"
#include "../../SharedUtility/CudaMacro.h"

int *BagManager::m_pInsWeight = NULL;
int BagManager::m_numBag = -1;
int BagManager::m_numIns = -1;
int BagManager::m_numFea = -1;
uint BagManager::m_numFeaValue = -1;

//tree information
int BagManager::m_numTreeEachBag = -1;
int BagManager::m_maxNumNode = -1;
int BagManager::m_maxNumSplittable = -1;
int BagManager::m_maxTreeDepth = -1;
int BagManager::m_maxNumLeave = -1;

//device memory
cudaStream_t *BagManager::m_pStream = NULL;
int *BagManager::m_pInsIdToNodeIdEachBag = NULL;//instance to node id (leaf nid may be smaller than maxNid)
int *BagManager::m_pInsWeight_d = NULL;

//for gd/hessian computation
//memory for initialisation
real *BagManager::m_pdTrueTargetValueEachBag = NULL;	//true target value of each instance
real *BagManager::m_pTargetValueEachBag = NULL;	//predicted target value of each instance
real *BagManager::m_pInsGradEachBag = NULL;
real *BagManager::m_pInsHessEachBag = NULL;

//for pinned memory; for computing indices in multiple level tree
uint *BagManager::m_pIndicesEachBag_d = NULL;	//indices for multiple level tree of each bag
uint *BagManager::m_pNumFvalueEachNodeEachBag_d = NULL;	//the number of feature values of each (splittable?) node
uint *BagManager::m_pFvalueStartPosEachNodeEachBag_d = NULL;//the start position of each node
uint *BagManager::m_pEachFeaStartPosEachNodeEachBag_d = NULL;//the start position of each feature in a node
int *BagManager::m_pEachFeaLenEachNodeEachBag_d = NULL;	//the number of values of each feature in each node

//memory for splittable nodes
TreeNode *BagManager::m_pSplittableNodeEachBag = NULL;
SplitPoint *BagManager::m_pBestSplitPointEachBag = NULL;//(require memset!) store the best split points
nodeStat *BagManager::m_pSNodeStatEachBag = NULL;	//splittable node statistics
nodeStat *BagManager::m_pRChildStatEachBag = NULL;
nodeStat *BagManager::m_pLChildStatEachBag = NULL;
int *BagManager::m_curNumofSplitableEachBag_h = NULL; //number of splittable node of current tree
int *BagManager::m_pPartitionId2SNPosEachBag = NULL;	//store all the buffer ids for splittable nodes

TreeNode *BagManager::m_pNodeTreeOnTrainingEachBag = NULL;//reserve memory for all nodes of the tree
//current numof nodes
int *BagManager::m_pCurNumofNodeTreeOnTrainingEachBag_d = NULL;
int *BagManager::m_pNumofNewNodeTreeOnTrainingEachBag = NULL;

//memory for parent node to children ids
int *BagManager::m_pParentIdEachBag = NULL;
int *BagManager::m_pLeftChildIdEachBag = NULL;
int *BagManager::m_pRightChildIdEachBag = NULL;
//memory for new node statistics
nodeStat *BagManager::m_pNewNodeStatEachBag = NULL;
TreeNode *BagManager::m_pNewNodeEachBag = NULL;
//memory for used features in the current splittable nodes
int *BagManager::m_pFeaIdToBuffIdEachBag = NULL;//(require memset!) map feature id to buffer id
int *BagManager::m_pUniqueFeaIdVecEachBag = NULL;	//store all the used feature ids
int *BagManager::m_pNumofUniqueFeaIdEachBag = NULL;//(require memset!)store the number of unique feature ids
int BagManager::m_maxNumUsedFeaATree = -1;	//for reserving GPU memory; maximum number of used features in a tree

//temp host variable
real *BagManager::m_pTrueLabel_h = NULL;

int *BagManager::m_pPreMaxNid_h = NULL;
uint *BagManager::m_pPreNumSN_h = NULL;
/**
 * @brief: initialise bag manager
 */
void BagManager::InitBagManager(int numIns, int numFea, int numTree, int numBag, int maxNumSN, int maxNumNode, long long numFeaValue,
								int maxNumUsedFeaInATree, int maxTreeDepth)
{
	int deviceId = -1;
	cudaGetDevice(&deviceId);
	printf("device id=%d\n", deviceId);

	GETERROR("error before init bag manager");
	printf("ins=%d, numBag=%d, maxSN=%d, maxNumNode=%d\n", numIns, numBag, maxNumSN, maxNumNode);
	PROCESS_ERROR(numIns > 0 && numBag > 0 && maxNumSN > 0 && maxNumNode > 0);
	m_numIns = numIns;
	m_numFea = numFea;
	m_numBag = numBag;
	m_numFeaValue = numFeaValue;

	//tree info
	m_numTreeEachBag = numTree;
	m_maxNumSplittable = maxNumSN;
	m_maxNumLeave = maxNumSN * 2;//2 times of the number of splittables (i.e. internal nodes)
	m_maxNumNode = maxNumNode;
	m_maxTreeDepth = maxTreeDepth;

	m_maxNumUsedFeaATree = maxNumUsedFeaInATree;

	BagBuilder bagBuilder;
	m_pInsWeight = new int[m_numIns * m_numBag];//bags are represented by weights to each instance
	bagBuilder.ContructBag(m_numIns, m_pInsWeight, m_numBag);
#if false
	for(int i = 0; i < m_numBag; i++)
	{
		int total = 0;
		for(int j = 0; j < m_numIns; j++)
		{
			total += m_pInsWeight[j + i * m_numIns];
		}
		if(total != m_numIns)
			cerr << "error in building bags" << endl;
	}
#endif
	GETERROR("error before create stream");

	printf("# of bags=%d\n", m_numBag);
	m_pStream = new cudaStream_t[numBag];
	for(int i = 0; i < m_numBag; i++)
		cudaStreamCreate(&m_pStream[i]);

	GETERROR("before allocate memory in BagManager");
	AllocMem();

	//initialise device memory
//	cudaMemcpy(m_pInsWeight_d, m_pInsWeight, sizeof(int) * m_numIns * m_numBag, cudaMemcpyHostToDevice);
	cudaMemset(m_pInsIdToNodeIdEachBag, 0, sizeof(int) * m_numIns * m_numBag);
}

/**
 * @brief: allocate device memory for each bag
 */
void BagManager::AllocMem()
{
	//instance information for each bag
	PROCESS_ERROR(m_numIns > 0 && m_numBag > 0);
	checkCudaErrors(cudaMalloc((void**)&m_pInsIdToNodeIdEachBag, sizeof(int) * m_numIns * m_numBag));
//	checkCudaErrors(cudaMalloc((void**)&m_pInsWeight_d, sizeof(int) * m_numIns * m_numBag));

	/******* memory for find split ******/
	//predicted value, gradient, hessian
	checkCudaErrors(cudaMalloc((void**)&m_pTargetValueEachBag, sizeof(real) * m_numIns * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pdTrueTargetValueEachBag, sizeof(real) * m_numIns * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pInsGradEachBag, sizeof(real) * m_numIns * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pInsHessEachBag, sizeof(real) * m_numIns * m_numBag));

	//for computing indices of more than one level trees
	checkCudaErrors(cudaMalloc((void**)&m_pIndicesEachBag_d, sizeof(uint) * m_numFeaValue * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pNumFvalueEachNodeEachBag_d, sizeof(uint) * m_maxNumSplittable * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pFvalueStartPosEachNodeEachBag_d, sizeof(uint) * m_maxNumSplittable * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pEachFeaStartPosEachNodeEachBag_d, sizeof(uint) * m_maxNumSplittable * m_numBag * m_numFea));
	checkCudaErrors(cudaMalloc((void**)&m_pEachFeaLenEachNodeEachBag_d, sizeof(int) * m_maxNumSplittable * m_numBag * m_numFea));

	/********** memory for splitting node ************/
	//for splittable nodes
	checkCudaErrors(cudaMalloc((void**)&m_pSplittableNodeEachBag, sizeof(TreeNode) * m_maxNumSplittable * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pBestSplitPointEachBag, sizeof(SplitPoint) * m_maxNumSplittable * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pSNodeStatEachBag, sizeof(nodeStat) * m_maxNumSplittable * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pRChildStatEachBag, sizeof(nodeStat) * m_maxNumSplittable * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pLChildStatEachBag, sizeof(nodeStat) * m_maxNumSplittable * m_numBag));
	//temporary space for splittable nodes
	m_curNumofSplitableEachBag_h = new int[m_numBag];
	//map splittable node to buffer id
	checkCudaErrors(cudaMalloc((void**)&m_pPartitionId2SNPosEachBag, sizeof(int) * m_maxNumSplittable * m_numBag));
	checkCudaErrors(cudaMemset(m_pPartitionId2SNPosEachBag, -1, sizeof(int) * m_maxNumSplittable * m_numBag));
	//for parent and children relationship
	checkCudaErrors(cudaMalloc((void**)&m_pParentIdEachBag, sizeof(int) * m_maxNumSplittable * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pLeftChildIdEachBag, sizeof(int) * m_maxNumSplittable * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pRightChildIdEachBag, sizeof(int) * m_maxNumSplittable * m_numBag));
	//memory for new node statistics
	checkCudaErrors(cudaMalloc((void**)&m_pNewNodeStatEachBag, sizeof(nodeStat) * m_maxNumLeave * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pNewNodeEachBag, sizeof(TreeNode) * m_maxNumLeave * m_numBag));
	//map splittable node to buffer id
	checkCudaErrors(cudaMalloc((void**)&m_pFeaIdToBuffIdEachBag, sizeof(int) * m_maxNumUsedFeaATree * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pUniqueFeaIdVecEachBag, sizeof(int) * m_maxNumUsedFeaATree * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pNumofUniqueFeaIdEachBag, sizeof(int) * m_numBag));

	/*********** memory for the tree (on training and final) ******/
	checkCudaErrors(cudaMalloc((void**)&m_pNodeTreeOnTrainingEachBag, sizeof(TreeNode) * m_maxNumNode * m_numBag));
	checkCudaErrors(cudaMalloc((void**)&m_pCurNumofNodeTreeOnTrainingEachBag_d, sizeof(int) * m_numBag));
	checkCudaErrors(cudaMemset(m_pCurNumofNodeTreeOnTrainingEachBag_d, 0, sizeof(int) * m_numBag));//this is needed as the init value is used.
	checkCudaErrors(cudaMalloc((void**)&m_pNumofNewNodeTreeOnTrainingEachBag, sizeof(int) * m_numBag));

	m_pPreMaxNid_h = new int[m_numBag];
	for(int i = 0; i < m_numBag; i++)
		m_pPreMaxNid_h[i] = -1;//initalise ids
	m_pPreNumSN_h = new uint[m_numBag];
	memset(m_pPreNumSN_h, 0, sizeof(uint) * m_numBag);
}

void BagManager::FreeMem()
{
	cudaFree(m_pInsIdToNodeIdEachBag);
//	cudaFree(m_pInsWeight_d);
	cudaFree(m_pTargetValueEachBag);
	cudaFree(m_pInsGradEachBag);
	cudaFree(m_pInsHessEachBag);
	delete []m_pInsWeight;
}
