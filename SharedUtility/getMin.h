/**
 * devUtility.h
 * @brief: This file contains InitCUDA() function and a reducer class CReducer
 * Created on: May 24, 2012
 * Author: Zeyi Wen
 * Copyright @DBGroup University of Melbourne
 **/

#ifndef GETMIN_H_
#define GETMIN_H_
#include <cuda_runtime.h>
#include "DataType.h"
#include "CudaMacro.h"

template<class T>
__device__ void GetMinValueOriginal(real *pfValues, T *pnKey)
{
	CONCHECKER(blockDim.x % 32 == 0);
	//Reduce by a factor of 2, and minimize step size
	for (int i = blockDim.x / 2; i > 0 ; i >>= 1) {
		int tid = threadIdx.x;
		if (tid < i){
			if (pfValues[tid + i] < pfValues[tid]) {
                pfValues[tid] = pfValues[tid + i];
                pnKey[tid] = pnKey[tid +i];
            }
		}
        __syncthreads();
	}
}

#endif /* GETMIN_H_ */
