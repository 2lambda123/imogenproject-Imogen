#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#ifdef UNIX
#include <stdint.h>
#include <unistd.h>
#endif
#include "mex.h"

// CUDA
#include "cuda.h"
#include "cuda_runtime.h"
#include "cublas.h"
#include "GPUmat.hh"

// static paramaters
static int init = 0;
static GPUmat *gm;

#include "cudaCommon.h"

__global__ void cukern_WFlux_mhd_uniform(fluidVarPtrs fluid, double lambda, int nu, int hu, int hv, int hw);
__global__ void cukern_WFlux_hydro_uniform(fluidVarPtrs fluid, double lambda, int nu, int hu, int hv, int hw);
__global__ void nullStep(fluidVarPtrs fluid, int numel);

#define BLOCKLEN 126

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
  // At least 2 arguments expected
  // Input and result
  if ((nrhs!=12) || (nlhs != 5)) mexErrMsgTxt("Wrong number of arguments: need [5] = cudaWflux(rho, E, px, py, pz, bx, by, bz, Ptot, c_f, lambda, purehydro?)\n");

  if (init == 0) {
    gm = gmGetGPUmat();
    init = 1;
  }

  // Get source array info and create destination arrays
  int numel;
  GPUtype srcReference = gm->gputype.getGPUtype(prhs[0]);

  double **srcs = getGPUSourcePointers(prhs, 10, &numel, 0, gm);
  double **dest = makeGPUDestinationArrays(srcReference,  plhs, 5, gm);

int jj;
for(jj=0; jj<10;jj++) { printf("%i, %i\n", jj, srcs[jj]); }

  // Establish launch dimensions & a few other parameters
  int fluxDirection = 1;
  double lambda     = *mxGetPr(prhs[10]);
  int numDims        = gm->gputype.getNdims(srcReference);
  const int *dims    = gm->gputype.getSize(srcReference);

  dim3 arraySize;
  arraySize.x = dims[0];
  numDims > 1 ? arraySize.y = dims[1] : arraySize.y = 1;
  numDims > 2 ? arraySize.z = dims[2] : arraySize.z = 1;

  dim3 blocksize, gridsize;
  int hu, hv, hw, nu;

  blocksize.x = BLOCKLEN+2; blocksize.y = blocksize.z = 1;
  switch(fluxDirection) {
    case 1: // X direction flux: u = x, v = y, w = z;
      gridsize.x = arraySize.y;
      gridsize.y = arraySize.z;
      hu = 1; hv = arraySize.x; hw = arraySize.x * arraySize.x;
      nu = arraySize.x; break;
    case 2: // Y direction flux: u = y, v = x, w = z
      gridsize.x = arraySize.x;
      gridsize.y = arraySize.z;
//      hu = arraySize.x; hv = 1; hw = arraySize.x * arraySize.y;
      hv = arraySize.x; hu = 1; hw = arraySize.x * arraySize.y;
      nu = arraySize.y; break;
    case 3: // Z direction flux: u = z, v = x, w = y;
      gridsize.x = arraySize.x;
      gridsize.y = arraySize.y;
      hu = arraySize.x * arraySize.y; hv = 1; hw = arraySize.x;
      nu = arraySize.z; break;
    }

fluidVarPtrs fluid;
int i;
for(i = 0; i < 5; i++) { fluid.fluidIn[i] = srcs[i]; fluid.fluidOut[i] = dest[i]; }
fluid.B[0] = srcs[5];
fluid.B[1] = srcs[6];
fluid.B[2] = srcs[7];

fluid.Ptotal = srcs[8];
fluid.cFreeze = srcs[9];

if(nu > 1) {
  int hydroOnly = (int)*mxGetPr(prhs[11]);

  if(hydroOnly == 1) {
    cukern_WFlux_hydro_uniform<<<gridsize, blocksize>>>(fluid, lambda, nu, hu, hv, hw);
    } else {
    cukern_WFlux_mhd_uniform<<<gridsize, blocksize>>>(fluid, lambda, nu, hu, hv, hw);
    }
  } else {
  nullStep<<<32, 128>>>(fluid, numel);
  }

}


__global__ void cukern_WFlux_mhd_uniform(fluidVarPtrs fluid, double lambda, int nu, int hu, int hv, int hw)
{

// This is the shared flux array.
// It is long enough to hold both the left and right fluxes for a variable, with extra spaces that
// strategically leave the next flux variables for the left edge behind when our fLeft pointer is decremented
__shared__ double fluxArrayL[BLOCKLEN+6];
__shared__ double fluxArrayR[BLOCKLEN+6];

// Local copies of the hyperbolic state variables: The conserved quantities Qi (rho, energy,
// momentum), a W variable, and local copies of the pressure, inverse freezing speed and B
double Qi[5], Wi, lPress, Cinv, lBx, lBy, lBz;

// IndexBase identifies where we go into the array, i is our generic counter variable
int indexBase;// = blockIdx.x * hv + blockIdx.y * hw + ((threadIdx.x-1)%nu)* hu;
//int endAddress = blockIdx.x * hv + blockIdx.y * hw + nu*hu;
int i;

// Pointer into the shared flux array that's strategically decremented to leave the variables we need next behind
double *fLeft; double *fRight;
double rhoinv;

// Loop index - controls the advancement of the thread block through the line; Doflux tells threads to flux or not flux
int lpIdx;

Cinv = 1.0/fluid.cFreeze[blockIdx.x + gridDim.x * blockIdx.y];

for(lpIdx = threadIdx.x-1; lpIdx <= nu; lpIdx += BLOCKLEN) {
	// Our index in the U direction; If it exceeds the array size+1, return; If it equals it, don't flux that cell

	// Convert i to an index; Circular boundary conditions
	indexBase = blockIdx.x * hv + blockIdx.y * hw + (lpIdx % nu)* hu;
if(lpIdx < 0) indexBase = blockIdx.x * hv + blockIdx.y * hw + (nu-1)* hu;

	// Load local copies of hyperbolic state variables
	for(i = 0; i < 5; i++) { Qi[i] = fluid.fluidIn[i][indexBase]; }
	lPress = fluid.Ptotal[indexBase];
/*	Cinv   = 1.0 / fluid.cFreeze[indexBase]; */
	rhoinv = 1.0 / Qi[0];
	lBx = fluid.B[0][indexBase];
	lBy = fluid.B[1][indexBase];
	lBz = fluid.B[2][indexBase];

	// Start outselves off with 4 chances to move left
	fLeft  = fluxArrayL + 4;
	fRight = fluxArrayR + 4;

	// For each conserved quantity,
	for(i = 0; i < 5; i++) {
		// Calculate the W flux
		switch(i) {
			case 0: Wi = Qi[2] * Cinv; break;
			case 1: Wi = (Qi[2] * (Qi[1] + lPress) - lBx*(Qi[2]*lBx+Qi[3]*lBy+Qi[4]*lBz) ) * Cinv * rhoinv; break;
			case 2: Wi = (Qi[2]*Qi[2]*rhoinv + lPress - lBx*lBx)*Cinv; break;
			case 3: Wi = (Qi[2]*Qi[3]*rhoinv          - lBx*lBy)*Cinv; break;
			case 4: Wi = (Qi[2]*Qi[4]*rhoinv          - lBx*lBz)*Cinv; break;
                        }
		// Decouple into left & right going fluxes
		fLeft[threadIdx.x]  = .5*(Qi[i] - Wi);
		fRight[threadIdx.x] = .5*(Qi[i] + Wi);

		// Stop until all threads finish filling flux array
		__syncthreads();

		// Write updated quantities to global memory
		if((lpIdx >= 0) && (lpIdx < nu)) {
fluid.fluidOut[i][indexBase] = Qi[i] - .5*lambda*( fLeft[threadIdx.x] - fLeft[threadIdx.x+1] + fRight[threadIdx.x] - fRight[threadIdx.x-1] )/Cinv;
//fluid.fluidOut[0][indexBase] = Qi[2];
//fluid.fluidOut[1][indexBase] = Qi[1];
//fluid.fluidOut[2][indexBase] = lPress;
//fluid.fluidOut[3][indexBase] = fLeft[threadIdx.x];
//fluid.fluidOut[4][indexBase] = fRight[threadIdx.x];
}

		// Make sure everyone's done reading shared memory before we futz with it again; Move left
		__syncthreads();
		fLeft--;
		fRight--;
		}

;
	// Thread zero is only to fill the left edge on the very first iteration - break
	if(threadIdx.x == 0) break;

	if(threadIdx.x < 6) {
		fluxArrayL[threadIdx.x-1] = fluxArrayL[threadIdx.x + BLOCKLEN];
		fluxArrayR[threadIdx.x-1] = fluxArrayR[threadIdx.x + BLOCKLEN];
		}

	}


}


__global__ void cukern_WFlux_hydro_uniform(fluidVarPtrs fluid, double lambda, int nu, int hu, int hv, int hw)
{

// This is the shared flux array.
// It is long enough to hold both the left and right fluxes for a variable, with extra spaces that
// strategically leave the next flux variables for the left edge behind when our fLeft pointer is decremented
__shared__ double fluxArrayL[BLOCKLEN+6];
__shared__ double fluxArrayR[BLOCKLEN+6];

// Local copies of the hyperbolic state variables: The conserved quantities Qi (rho, energy,
// momentum), a W variable, and local copies of the pressure, inverse freezing speed and B
double Qi[5], Wi, lPress, Cinv;

// IndexBase identifies where we go into the array, i is our generic counter variable
int indexBase;// = blockIdx.x * hv + blockIdx.y * hw + ((threadIdx.x-1)%nu)* hu;
//int endAddress = blockIdx.x * hv + blockIdx.y * hw + nu*hu;
int i;

// Pointer into the shared flux array that's strategically decremented to leave the variables we need next behind
double *fLeft; double *fRight;
double rhoinv;

// Loop index - controls the advancement of the thread block through the line; Doflux tells threads to flux or not flux
int lpIdx;

Cinv = 1.0/fluid.cFreeze[blockIdx.x + gridDim.x * blockIdx.y];

for(lpIdx = threadIdx.x-1; lpIdx <= nu; lpIdx += BLOCKLEN) {
        // Our index in the U direction; If it exceeds the array size+1, return; If it equals it, don't flux that cell

        // Convert i to an index; Circular boundary conditions
        indexBase = blockIdx.x * hv + blockIdx.y * hw + (lpIdx % nu)* hu;
if(lpIdx < 0) indexBase = blockIdx.x * hv + blockIdx.y * hw + (nu-1)* hu;

        // Load local copies of hyperbolic state variables
        for(i = 0; i < 5; i++) { Qi[i] = fluid.fluidIn[i][indexBase]; }
        lPress = fluid.Ptotal[indexBase];
/*        Cinv   = 1.0 / fluid.cFreeze[indexBase];*/
        rhoinv = 1.0 / Qi[0];

        // Start outselves off with 4 chances to move left
        fLeft  = fluxArrayL + 4;
        fRight = fluxArrayR + 4;

        // For each conserved quantity,
        for(i = 0; i < 5; i++) {
                // Calculate the W flux
                switch(i) {
                        case 0: Wi = Qi[2] * Cinv; break;
                        case 1: Wi = (Qi[2] * (Qi[1] + lPress)) * Cinv * rhoinv; break;
                        case 2: Wi = (Qi[2]*Qi[2]*rhoinv + lPress )*Cinv; break;
                        case 3: Wi = (Qi[2]*Qi[3]*rhoinv          )*Cinv; break;
                        case 4: Wi = (Qi[2]*Qi[4]*rhoinv          )*Cinv; break;
                        }

                // Decouple into left & right going fluxes
                fLeft[threadIdx.x]  = .25*(Qi[i] - Wi);
                fRight[threadIdx.x] = .25*(Qi[i] + Wi);

                // Stop until all threads finish filling flux array
                __syncthreads();

                // Write updated quantities to global memory
                if((lpIdx >= 0) && (lpIdx < nu)) fluid.fluidOut[i][indexBase] = Qi[i] - lambda*( fLeft[threadIdx.x] - fLeft[threadIdx.x+1] + fRight[threadIdx.x] - fRight[threadIdx.x-1] )/Cinv;

                // Make sure everyone's done reading shared memory before we futz with it again; Move left
                __syncthreads();
                fLeft--;
                fRight--;
                }

;
        // Thread zero is only to fill the left edge on the very first iteration - break
        if(threadIdx.x == 0) break;

        if(threadIdx.x < 6) {
                fluxArrayL[threadIdx.x-1] = fluxArrayL[threadIdx.x + BLOCKLEN];
                fluxArrayR[threadIdx.x-1] = fluxArrayR[threadIdx.x + BLOCKLEN];
                }

        }


}


// Function simply blits fluid input variables to output, since with only 1 plane there's no derivative possible.
__global__ void nullStep(fluidVarPtrs fluid, int numel)
{
int idx0 = threadIdx.x + blockIdx.x*blockDim.x;
int didx = blockDim.x * gridDim.x;
int i;

while(idx0 < numel) {
  for(i = 0; i < 5; i++) { fluid.fluidOut[i][idx0] = fluid.fluidIn[i][idx0]; }

  idx0 += didx;
  }

}

