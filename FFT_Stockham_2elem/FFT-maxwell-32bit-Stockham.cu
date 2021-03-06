#include <cufft.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include "debug.h"
#include "timer.h"
#include "utils_cuda.h"
#include "utils_file.h"

#include "params.h"


#define WARP 32


int device=0;

__device__ __inline__ float2 Get_W_value(int N, int m){
	float2 ctemp;
	ctemp.x=cosf( -2.0f*3.141592654f*fdividef( (float) m, (float) N) );
	ctemp.y=sinf( -2.0f*3.141592654f*fdividef( (float) m, (float) N) );
	return(ctemp);
}


__device__ void do_FFT(float2 *s_input){
	float2 DFT_value_even, DFT_value_odd, ftemp2, ftemp;
	float2 W;
	
	int r, j, k, PoT, PoTm1, A_index, B_index, Nhalf;

	Nhalf=FFT_LENGTH>>1;
	
	//-----> FFT
	//--> 
	
	PoT=1;
	PoTm1=0;
	//------------------------------------------------------------
	// First iteration
		PoTm1=PoT;
		PoT=PoT<<1;
		
		j=threadIdx.x;
		k=0;
		
		W.x=1;
		W.y=0;

		A_index=j*PoTm1;
		B_index=j*PoTm1 + Nhalf;
		
		ftemp2=s_input[B_index];
		ftemp=s_input[A_index];
		
		DFT_value_even.x=ftemp.x + W.x*ftemp2.x - W.y*ftemp2.y;
		DFT_value_even.y=ftemp.y + W.x*ftemp2.y + W.y*ftemp2.x;
		
		DFT_value_odd.x=ftemp.x - W.x*ftemp2.x + W.y*ftemp2.y;
		DFT_value_odd.y=ftemp.y - W.x*ftemp2.y - W.y*ftemp2.x;
		
		__syncthreads();
		s_input[j*PoT]=DFT_value_even;
		s_input[j*PoT + PoTm1]=DFT_value_odd;
		__syncthreads();
	// First iteration
	//------------------------------------------------------------
	
	for(r=2;r<=FFT_EXP;r++){
		PoTm1=PoT;
		PoT=PoT<<1;
		
		j=threadIdx.x>>(r-1);
		k=threadIdx.x & (PoTm1-1);
		
		W=Get_W_value(PoT,k);

		A_index=j*PoTm1 + k;
		B_index=j*PoTm1 + k + Nhalf;
		
		ftemp2=s_input[B_index];
		ftemp=s_input[A_index];
		
		DFT_value_even.x=ftemp.x + W.x*ftemp2.x - W.y*ftemp2.y;
		DFT_value_even.y=ftemp.y + W.x*ftemp2.y + W.y*ftemp2.x;
		
		DFT_value_odd.x=ftemp.x - W.x*ftemp2.x + W.y*ftemp2.y;
		DFT_value_odd.y=ftemp.y - W.x*ftemp2.y - W.y*ftemp2.x;
		
		__syncthreads();
		s_input[j*PoT + k]=DFT_value_even;
		s_input[j*PoT + k + PoTm1]=DFT_value_odd;
		__syncthreads();
	}
	//-------> END
}


__global__ void FFT_GPU_external(float2 *d_input, float2* d_output) {
	extern __shared__ float2 s_input[];
	s_input[threadIdx.x]=d_input[threadIdx.x + blockIdx.x*FFT_LENGTH];
	s_input[threadIdx.x + FFT_LENGTH/2]=d_input[threadIdx.x + FFT_LENGTH/2 + blockIdx.x*FFT_LENGTH];
	
	__syncthreads();
	do_FFT(s_input);	
	__syncthreads();
	
	d_output[threadIdx.x + blockIdx.x*FFT_LENGTH]=s_input[threadIdx.x];
	d_output[threadIdx.x + FFT_LENGTH/2 + blockIdx.x*FFT_LENGTH]=s_input[threadIdx.x + FFT_LENGTH/2];
}


__global__ void FFT_GPU_multiple(float2 *d_input, float2* d_output) {
	extern __shared__ float2 s_input[];
	s_input[threadIdx.x]=d_input[threadIdx.x + blockIdx.x*FFT_LENGTH];
	s_input[threadIdx.x + FFT_LENGTH/2]=d_input[threadIdx.x + FFT_LENGTH/2 + blockIdx.x*FFT_LENGTH];
	
	__syncthreads();
	for(int f=0;f<100;f++){
		do_FFT(s_input);
	}	
	__syncthreads();
	
	d_output[threadIdx.x + blockIdx.x*FFT_LENGTH]=s_input[threadIdx.x];
	d_output[threadIdx.x + FFT_LENGTH/2 + blockIdx.x*FFT_LENGTH]=s_input[threadIdx.x + FFT_LENGTH/2];
}


int Max_columns_in_memory_shared(int nSamples, int nSpectra) {
	long int nColumns,maxgrid_x;

	size_t free_mem,total_mem;
	cudaDeviceProp devProp;
	
	checkCudaErrors(cudaSetDevice(device));
	checkCudaErrors(cudaGetDeviceProperties(&devProp,device));
	maxgrid_x = devProp.maxGridSize[0];
	cudaMemGetInfo(&free_mem,&total_mem);
	
	nColumns=((long int) free_mem)/(2.0*sizeof(float2)*nSamples);
	if(nColumns>maxgrid_x) nColumns=maxgrid_x;
	nColumns=(int) nColumns*0.9;
	return(nColumns);
}


void FFT_init(){
	//---------> Specific nVidia stuff
	cudaDeviceSetCacheConfig(cudaFuncCachePreferShared);
	cudaDeviceSetSharedMemConfig(cudaSharedMemBankSizeEightByte);
}


void FFT_external_benchmark(float2 *d_input, float2 *d_output, int nSamples, int nSpectra, double *FFT_time){
	GpuTimer timer;
	//---------> CUDA block and CUDA grid parameters
	int nCUDAblocks_x=nSpectra;
	int nCUDAblocks_y=1;
	
	dim3 gridSize(nCUDAblocks_x, nCUDAblocks_y, 1);
	dim3 blockSize(nSamples/2, 1, 1);
	
	//---------> FIR filter part
	timer.Start();
	FFT_GPU_external<<<gridSize, blockSize,nSamples*8>>>( d_input, d_output);
	timer.Stop();
	*FFT_time += timer.Elapsed();
}

void FFT_multiple_benchmark(float2 *d_input, float2 *d_output, int nSamples, int nSpectra, double *FFT_time){
	GpuTimer timer;
	//---------> CUDA block and CUDA grid parameters
	dim3 gridSize_multiple(1000, 1, 1);
	dim3 blockSize(nSamples/2, 1, 1);
	
	//---------> FIR filter part
	timer.Start();
	FFT_GPU_multiple<<<gridSize_multiple, blockSize,nSamples*8>>>( d_input, d_output);
	timer.Stop();
	*FFT_time += timer.Elapsed();
}


int GPU_FFT(float2 *h_input, float2 *h_output, int nSamples, int nSpectra, int nRuns){
	//---------> Initial nVidia stuff
	int devCount;
	size_t free_mem,total_mem;
	checkCudaErrors(cudaGetDeviceCount(&devCount));
	checkCudaErrors(cudaSetDevice(device));
	
	cudaMemGetInfo(&free_mem,&total_mem);
	if(DEBUG) printf("\nDevice has %ld MB of total memory, which %ld MB is available.\n", (long int) total_mem/(1000*1000), (long int) free_mem/(1000*1000));
	
	//---------> Checking memory
	int nElements=nSamples*nSpectra;
	int input_size=nElements;
	int output_size=nElements;
	
	float free_memory = (float) free_mem/(1024.0*1024.0);
	float memory_required=((2*input_size + 2*output_size)*sizeof(float))/(1024.0*1024.0);
	if(DEBUG) printf("DEBUG: Device has %0.3f MB of total memory, which %0.3f MB is available. Memory required %0.3f MB\n", (float) total_mem/(1024.0*1024.0), free_memory ,memory_required);
	if(memory_required>free_memory) {printf("\n \n Array is too big for the device! \n \n"); return(-3);}
		
	//---------> Measurements
	double transfer_in, transfer_out, FFT_time, FFT_external_time, FFT_multiple_time, FFT_multiple_reuse_time,cuFFT_time,FFT_multiple_reuse_registers_time;
	double FFT_multiple_time_total, FFT_external_time_total;
	GpuTimer timer;
	
	
	//------------------------------------------------------------------------------
	//---------> Shared memory kernel
	transfer_in=0.0; transfer_out=0.0; FFT_time=0.0; FFT_external_time=0.0; FFT_multiple_time=0.0; FFT_multiple_reuse_time=0.0; cuFFT_time=0.0; FFT_multiple_reuse_registers_time=0.0;
	FFT_multiple_time_total = 0; FFT_external_time_total = 0;
	
	//---------> Memory allocation
	if (DEBUG) printf("Device memory allocation...: \t\t");
	float2 *d_output;
	float2 *d_input;
	timer.Start();
	checkCudaErrors(cudaMalloc((void **) &d_input,  sizeof(float2)*input_size));
	checkCudaErrors(cudaMalloc((void **) &d_output, sizeof(float2)*output_size));
	timer.Stop();
	if (DEBUG) printf("done in %g ms.\n", timer.Elapsed());

	//---------> FFT calculation
	if (DEBUG) printf("Transferring data to device...: \t");
	timer.Start();
	checkCudaErrors(cudaMemcpy(d_input, h_input, input_size*sizeof(float2), cudaMemcpyHostToDevice));
	timer.Stop();
	transfer_in+=timer.Elapsed();
	if (DEBUG) printf("done in %g ms.\n", timer.Elapsed());
	
	//-----> Compute FFT on the chunk
	if(CUFFT){
		//---------> FFT
		cufftHandle plan;
		cufftResult error;
		error = cufftPlan1d(&plan, nSamples, CUFFT_C2C, nSpectra);
		if (CUFFT_SUCCESS != error){
			printf("CUFFT error: %d", error);
		}
		
		timer.Start();
		cufftExecC2C(plan, (cufftComplex *)d_input, (cufftComplex *)d_output, CUFFT_FORWARD);
		timer.Stop();
		cuFFT_time += timer.Elapsed();
		
		cufftDestroy(plan);
	}
	
	if(MULTIPLE){
		if (DEBUG) printf("Multiple FFT...: \t\t\t");
		FFT_init();
		FFT_multiple_time_total = 0;
		for(int f=0; f<nRuns; f++){
			checkCudaErrors(cudaMemcpy(d_input, h_input, input_size*sizeof(float2), cudaMemcpyHostToDevice));
			FFT_multiple_benchmark(d_input, d_output, nSamples, nSpectra, &FFT_multiple_time_total);
		}
		FFT_multiple_time = FFT_multiple_time_total/nRuns;
		if (DEBUG) printf("done in %g ms.\n", FFT_multiple_time);
	}
    
	if(EXTERNAL){
		if (DEBUG) printf("FFT...: \t\t\t\t");
		FFT_init();
		FFT_external_time_total = 0;
		for(int f=0; f<nRuns; f++){
			checkCudaErrors(cudaMemcpy(d_input, h_input, input_size*sizeof(float2), cudaMemcpyHostToDevice));
			FFT_external_benchmark(d_input, d_output, nSamples, nSpectra, &FFT_external_time_total);
		}
		FFT_external_time = FFT_external_time_total/nRuns;
		if (DEBUG) printf("done in %g ms.\n", FFT_external_time);
	}
	
	//-----> Copy chunk of output data to host
	if (DEBUG) printf("Transferring data to host...: \t\t");
	timer.Start();
	checkCudaErrors(cudaMemcpy( h_output, d_output, output_size*sizeof(float2), cudaMemcpyDeviceToHost));
	timer.Stop();
	transfer_out+=timer.Elapsed();
	if (DEBUG) printf("done in %g ms.\n", timer.Elapsed());
	

	

	//---------> error check -----
	checkCudaErrors(cudaGetLastError());
	
	//---------> Feeing allocated resources
	checkCudaErrors(cudaFree(d_input));
	checkCudaErrors(cudaFree(d_output));
	
	if (DEBUG || WRITE) printf("nSpectra:%d; nSamples:%d cuFFT:%0.3f ms; FFT:%0.3f ms; FFT external:%0.3f ms; FFT multiple:%0.3f ms;\n",nSpectra,nSamples,cuFFT_time, FFT_time, FFT_external_time, FFT_multiple_time);	
	
	if (WRITE){ 
		char str[200];
		sprintf(str,"GPU-FFT-Stockham.dat");
		if (DEBUG) printf("\n Write results into file...\t");
		save_time(str, nSpectra,nSamples, cuFFT_time, FFT_time, FFT_external_time, FFT_multiple_time, FFT_multiple_reuse_time, FFT_multiple_reuse_registers_time, transfer_in, transfer_out);
		if (DEBUG) printf("\t done.\n-------------------------------------\n");
	}
	
	return(1);
}