/*
 * NodeStat.h
 *
 *  Created on: 12 Apr 2016
 *      Author: Zeyi Wen
 *		@brief: node statistics
 */

#ifndef NODESTAT_H_
#define NODESTAT_H_


#include <iostream>
#include "MyAssert.h"
#include "DefineConst.h"

using std::cout;
using std::endl;

class nodeStat{
public:
	float_point sum_gd;
	float_point sum_hess;

	nodeStat()
	{
		sum_gd = 0.0;
		sum_hess = 0.0;
	}

	bool IsEmpty() const{
		return sum_hess == 0.0;
	}

	void Subtract(const nodeStat &parent, const nodeStat &r_child)
	{
		sum_gd = parent.sum_gd - r_child.sum_gd;
		PROCESS_ERROR(parent.sum_gd - sum_gd - r_child.sum_gd < 0.0001);
		sum_hess = parent.sum_hess - r_child.sum_hess;
		PROCESS_ERROR(sum_hess >= 0);
	}
	void Add(float_point gd, float_point hess)
	{
		sum_gd += gd;
		sum_hess += hess;
	}
};



#endif /* NODESTAT_H_ */