#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <helper_cuda.h>
#include "helper.cuh"
#include "ga.cuh"

__device__ size_t d_npop;
__device__ size_t d_ngen;

// chromosome for [sz_taks * d_npop*2]
int * h_chrm;
int * h_chrm_s;
/************************************************************************/
/* hash value for each person                                           */
/************************************************************************/
unsigned long * h_hashv;
unsigned long * h_hashv_s;
/************************************************************************/
/* you can get fitness value like this:                                 */
/*      h_fitv[ itask-1 ]];                                             */
/************************************************************************/
float * h_fitv;
float * h_fitv_s;

// host data for display result
int * chrm;
unsigned long * hashv;
float * fitv;

void cuGaEvolve()
{
    
    // Choose which GPU to run on, change this on a multi-GPU system.
    checkCudaErrors(cudaSetDevice(0));

    // Allocate GPU buffer
    allocMemOnDevice();

    // transfer data to GPU
    moveDataToDevice();

    if (ntask > MAX_CHRM_LEN) {
        fprintf(stderr, "ntask = %d (> MAX_CHRM_LEN)\n", ntask);
        exit(1);
    }

    // Launch a kernel on the GPU with one thread for each element.
    gaEvolve(npop, ngen);

    // Check for any errors launching the kernel
    checkCudaErrors(cudaGetLastError());

    
    // cudaDeviceSynchronize waits for the kernel to finish, and returns
    // any errors encountered during the launch.
    checkCudaErrors(cudaDeviceSynchronize());

ERROR:
    freeMemOnDevice();
}

__global__ void gaSetPara(size_t npop, size_t ngen)
{
    d_npop = npop;
    d_ngen = ngen;
}

void gaAllocMem()
{
    size_t m_size;

    // chromosome attribution of a person
    m_size = 2 * npop * ntask * sizeof(int);
    checkCudaErrors(cudaMalloc((void **)&h_chrm, m_size));
    m_size = npop * ntask * sizeof(int);
    checkCudaErrors(cudaMalloc((void **)&h_chrm_s, m_size));

    
    // hash value attribution of a person
    m_size = 2 * npop * sizeof(unsigned long);
    checkCudaErrors(cudaMalloc((void **)&h_hashv, m_size));
    m_size = npop * sizeof(unsigned long);
    checkCudaErrors(cudaMalloc((void **)&h_hashv_s, m_size));

    // fitness value attribution of a person
    m_size = 2 * npop * sizeof(float);
    checkCudaErrors(cudaMalloc((void **)&h_fitv, m_size));
    m_size = npop * sizeof(float);
    checkCudaErrors(cudaMalloc((void **)&h_fitv_s, m_size));


    chrm = (int *) calloc(npop * ntask, sizeof(int));
    assert(chrm != 0);
    hashv = (unsigned long *) calloc(npop, sizeof(unsigned long));
    assert(hashv != 0);
    fitv = (float *) calloc(npop, sizeof(float));
    assert(fitv != 0);
}

void gaFreeMem()
{
    checkCudaErrors(cudaFree(h_chrm));
    checkCudaErrors(cudaFree(h_chrm_s));
    checkCudaErrors(cudaFree(h_hashv));
    checkCudaErrors(cudaFree(h_hashv_s));
    checkCudaErrors(cudaFree(h_fitv));
    checkCudaErrors(cudaFree(h_fitv_s));

    free(chrm);
    free(hashv);
    free(fitv);
}

static void dbPrintPerson(int * person, size_t n, char * tag)
{
    size_t i;

    printf("%s : ", tag);
    for (i = 0; i < n; i++) {
        printf("%d", person[i]);
        if (i < n-1) {
            printf("->");
        } else {
            printf("\n");
        }
    }

}

void dbDisplayWorld()
{
    size_t i;

    checkCudaErrors(cudaMemcpy(chrm, h_chrm, npop * ntask * sizeof(int), cudaMemcpyDeviceToHost));
    checkCudaErrors(cudaMemcpy(hashv, h_hashv, npop * sizeof(unsigned long), cudaMemcpyDeviceToHost));
    checkCudaErrors(cudaMemcpy(fitv, h_fitv, npop * sizeof(float), cudaMemcpyDeviceToHost));

    for (i = 0; i < npop; i++) {;
        char tag[100];
        sprintf(tag, "i%04d\th%08u\tf%f\t",i, hashv[i], fitv[i]);
        dbPrintPerson(chrm+i*ntask, ntask, tag);
    }
}

void gaEvolve(size_t npop, size_t ngen)
{
    gaSetPara<<<1, 1>>>(npop, ngen);
    gaAllocMem();
    size_t msize_occupy;
    msize_occupy = npop * nreso * sizeof(float);
    if (msize_occupy > MAX_SHARED_MEM) {
        fprintf(stderr, "msize_occupy = %d (> MAX_SHARED_MEM(%d))\n", msize_occupy, MAX_SHARED_MEM);
        exit(1);
    }
    gaInit<<<1, npop, msize_occupy>>>(h_chrm, h_hashv, h_fitv);
    dbDisplayWorld();
    gaFreeMem();
}


/************************************************************************/
/* Initialize a person                                                  */
/************************************************************************/
__global__ void gaInit(int * h_chrm, unsigned long * h_hashv, float * h_fitv)
{
    int * person;
    size_t tid = threadIdx.x;
    extern __shared__ float sh_occupys[];
    float * occupy;

    person = h_chrm + d_ntask * tid;
    occupy = sh_occupys + tid * d_nreso;

    size_t i;
    for (i = 0; i < d_ntask; i++) {
        person[i] = i+1;
    }

    size_t a, b;
    for (i = 0; i < d_ntask; i++) {
        randInt(&a, 0, d_ntask-1);
        b = i; 
        if (a > b) {
            int tmp;
            tmp=a; a=b; b=tmp;
        }

        swapBits(a, b, person);
    }

    h_hashv[tid] = hashfunc(person, d_ntask);
    h_fitv[tid] = gaObject(person, occupy);
    // printf("%d %08u %f\n", tid, h_hashv[tid], h_fitv[tid]);
    __syncthreads();
}


__global__ void gaCrossover(int * h_chrm, unsigned long * h_hashv, float * h_fitv)
{
    int * dad, * mom, * bro, * sis, * person;
    size_t a, b, tid;
    size_t i, j, k;
    bool needCrossover;

    float * occupy;
    extern __shared__ float sh_occupys[];

    tid = threadIdx.x;
    occupy = sh_occupys + tid * d_nreso;
    
    needCrossover = true;
    while (needCrossover) { 
        randInt(&a, 0, d_npop-1);
        randInt(&b, 0, d_npop-1);
        dad = h_chrm + a * d_ntask;
        mom = h_chrm + b * d_ntask;
        bro = h_chrm + ( 2*tid + d_npop) * d_ntask;
        sis = h_chrm + ( 2*tid + 1 + d_npop) * d_ntask;

        crossover(dad, mom, bro, sis);

        if (!check(bro)) {
            fixPerson(bro);
        }
        if (!check(sis)) {
            fixPerson(sis);
        }

        h_hashv[2*tid] = hashfunc(bro, d_ntask);
        h_hashv[2*tid+1] = hashfunc(bro, d_ntask);

        needCrossover = false;
        for (j = 0; j < d_npop; j++) {
            // check for brother
            if (h_hashv[2*tid] == h_hashv[j]) {
                person = h_chrm + j*d_ntask;
                for (k = 0; k < d_ntask; k++) {
                    if (bro[k] != person[k])
                        break;
                }
                if (k == d_ntask) {
                    // need re-crossover
                    needCrossover = true;
                    break;
                }
            }
            // check for sister
            if (h_hashv[2*tid+1] == h_hashv[j]) {
                person = h_chrm + j*d_ntask;
                for (k = 0; k < d_ntask; k++) {
                    if (sis[k] != person[k])
                        break;
                }
                if (k == d_ntask) {
                    // need re-crossover
                    needCrossover = true;
                    break;
                }
            }
        }

        if (!needCrossover) {
            h_fitv[2*tid] = gaObject(bro, occupy);
            h_fitv[2*tid+1] = gaObject(sis, occupy);
        }
    }
}

/************************************************************************/
/* ordering-based two points crossover                                  */
/************************************************************************/
__device__ void crossover(int * dad, int * mom, int * bro, int * sis)
{
    size_t i, j, k, a, b;
    int dad_new[MAX_CHRM_LEN], mom_new[MAX_CHRM_LEN];
    randInt(&a, 0, d_ntask-1);
    randInt(&b, 0, d_ntask-1);
    if (a > b) {
        size_t tmp;
        tmp=a; a=b; b=tmp;
    }

    for (i = 0; i < d_ntask; i++) {
        dad_new[i] = dad[i];
        mom_new[i] = mom[i];
        bro[i] = 0;
        sis[i] = 0;
    }

    // copy selected continuous region first (part1)
    for (i = a; i <= b; i++) {
        bro[i] = mom[i];
        sis[i] = dad[i];
    }

    // remove duplicated items
    for (k = 0; k < d_ntask; k++) {
        for (i = a; i <= b; i++) {
            if (dad_new[k] == mom[i]) {
                dad_new[k] = 0;
                break;
            }
        }
        for (i = a; i <= b; i++) {
            if (mom_new[k] == dad[i]) {
                mom_new[k] = 0;
                break;
            }
        }
    }

    
    // copy remainder region (part2)
    i = j = 0;
    for (k = 0; k < d_ntask; k++) {
        if (bro[k] == 0) {
            for (; i < d_ntask; i++) {
                if (dad_new[i] != 0) {
                    bro[k] = dad_new[i++];
                    break;
                }
            }
        }
        if (sis[k] == 0) {
            for (; j < d_ntask; j++) {
                if (mom_new[j] != 0) {
                    sis[k] = mom_new[j++];
                    break;
                }
            }
        }
    }

}

/****************************************************************************/
/* return true, if a-th task swap with b-th task; otherwise, return false.  */
/****************************************************************************/
__device__ bool swapBits(size_t a, size_t b, int * person)
{
    bool ret = true;
    // notice that, a < b
    if (a >= b) {
        ret = false;
    } else {
        size_t i, a_itask, b_itask, k_itask;
        a_itask = person[a];
        b_itask = person[b];
        for (i = a; i <= b; i++) {
            k_itask = person[i];
            if ( (i!=a) && isDepend(a_itask, k_itask) ){
                ret = false;
                break;
            }
            if ( (i!=b) && isDepend(k_itask, b_itask) ) {
                ret = false;
                break;
            }
        }
    }
    
    if (ret) {
        int tmp;
        tmp=person[a]; person[a]=person[b]; person[b]=tmp;
    }

    return ret;
}


#define HASH_SHIFT (3)
#define HASH_SIZE (19921104)
__device__ unsigned long hashfunc(int * person, size_t num)
{
    unsigned long hash_value;
    hash_value = 0;
    for (size_t i = 0; i < num; i++) {
        hash_value = (((unsigned long)person[i] + hash_value) << HASH_SHIFT ) % HASH_SIZE;
    }
    return hash_value;
}

__device__ float gaObject(int * person, float * occupy)
{
    float score;
    if (check(person)) {
        scheFCFS(person, occupy);
        score = getMaxTotalOccupy(occupy);
        if (score == 0.0f) {
            score = INF_DURATION;
        }
    } else {
        score = INF_DURATION;
    }
    return score;
}

/************************************************************************/
/*   feasibility check for <chromo_id>-th chromosome.                   */
/*       return true, if pass; otherwise, return false                  */
/************************************************************************/
__device__ bool check(int * person)
{
    size_t i, j;
    for (i = 0; i < d_ntask; i++) {
        for (j = i+1; j < d_ntask; j++) {
            int i_itask, j_itask;
            i_itask = person[i];
            j_itask = person[j];

            if (isDepend(j_itask, i_itask)) {
                // printf("failed depend %d -> %d\n", j_itask, i_itask);
                return false;
            }
        }
    }
    return true;
}

/************************************************************************/
/* scheduler, implement FCFS (first come, first service).               */
/************************************************************************/
__device__ void scheFCFS(int * person, float * occupy)
{
    size_t i, r, itask;

    // set temporary data struct as 0
    clearResouceOccupy(occupy);
    for (i = 0; i < d_ntask; i++) {
        itask = person[i];
        float dura = getDuration(itask);

        size_t min_id = 0;
        float min_occ, occ;
        for (r = 1; r <= d_nreso; r++) { // search all resources
            if (isAssign(itask,r)) {
                if (min_id == 0) {
                    min_occ = getTotalOccupy(r, occupy);
                    min_id = r;
                } else {
                    occ = getTotalOccupy(r, occupy);
                    if (occ < min_occ) {
                        min_occ = occ;
                        min_id = r;
                    }
                }
            }
        }

        if (min_id > 0) {
            allocResouce(min_id, dura, occupy);
        } else {
            allocResouce(1, dura, occupy);
        }
    }
}

/************************************************************************/
/* move a person[ele] several steps forward                             */
/************************************************************************/
__device__ void personMoveForward(int * person, size_t ele, size_t step)
{
    int tmp;
    size_t i;
    tmp = person[ele];
    for (i = ele; i < ele + step; i++) {
        person[i] = person[i+1];
    }
    person[ele+step] = tmp;
}

__device__ void fixPerson(int * person)
{
    size_t i, j, step;
    i = 0;
    while (i < d_ntask) {                       // FOR all tasks listed in person array

        // Number of steps to move elements forward?
        step = 0;
        for (j = i+1; j < d_ntask; j++) {
            if (isDepend(person[j], person[i]))
                step = j-i;
        }

        if (step > 0) {
            personMoveForward(person, i, step);
        } else {
            // if no use to move, then i++
            i++;
        }

    }
}