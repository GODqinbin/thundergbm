/*
 * BaseSplitter.h
 *
 *  Created on: 5 May 2016
 *      Author: Zeyi Wen
 *		@brief: 
 */

#ifndef BASESPLITTER_H_
#define BASESPLITTER_H_

#include <vector>
#include <unordered_map>
#include <string>

#include "../TreeNode.h"
#include "../NodeStat.h"
#include "../../Host/GDPair.h"
#include "../../Host/Tree/RegTree.h"
#include "../../Host/UpdateOps/SplitPoint.h"
#include "../../SharedUtility/KeyValue.h"

using std::vector;
using std::unordered_map;
using std::string;

class BaseSplitter
{
public:
	static vector<vector<KeyValue> > m_vvFeaInxPair; //value is feature value (sorted in a descendant order); id is instance id
	static unordered_map<int, int> mapNodeIdToBufferPos;
	static vector<int> m_nodeIds; //instance id to node id
	static vector<gdpair> m_vGDPair_fixedPos;
	static vector<nodeStat> m_nodeStat; //all the constructed tree nodes
	static real m_lambda;//the weight of the cost of complexity of a tree
	static real m_gamma;//the weight of the cost of the number of trees

public:
	virtual ~BaseSplitter(){}

public:
	//for sorting on each feature
	const static int LEAFNODE = -2;

	static constexpr float rt_eps = 1e-6;
	static constexpr double min_child_weight = 1.0;//follow xgboost

public:
	//for debugging
	template<class T>
	void PrintVec(vector<T> &vec)
	{
		int nNumofEle = vec.size();
		for(int i = 0; i < nNumofEle; i++)
		{
			cout << vec[i] << "\t";
		}
		cout << endl;
	}
	virtual void ComputeGD(vector<RegTree> &vTree, vector<vector<KeyValue> > & vvInsSparse,  void *stream, int bagId) = 0;
public:
	int m_nRound;
	int m_nCurDept;
};




#endif /* BASESPLITTER_H_ */
