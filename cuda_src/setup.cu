/**
 * Copyright 1993-2015 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */

/**
 * Vector addition: C = A + B.
 *
 * This sample is a very basic sample that implements element by element
 * vector addition. It is the same as the sample illustrating Chapter 2
 * of the programming guide with some additions like error checking.
 */

#include <stdio.h>
#include <iostream>

// For the CUDA runtime routines (prefixed with "cuda_")
#include <cuda_runtime.h>

#include "kernel.cu"
#include <map>


/**
 * CUDA Kernel Device code
 *
 * Computes the vector addition of A and B into C. The 3 vectors have the same
 * number of elements numElements.
 */
using namespace std;

extern __global__ void printInfo();

CUDAPathTracer::CUDAPathTracer(PathTracer* _pathTracer)
{
    pathTracer = _pathTracer;
}

CUDAPathTracer::~CUDAPathTracer()
{
    cudaFree(gpu_types);
    cudaFree(gpu_bsdfIndexes);
    cudaFree(gpu_positions);
    cudaFree(gpu_normals);
    cudaFree(frameBuffer);
}


void CUDAPathTracer::startRayTracing()
{
    int blockDim = 256;
    int gridDim = (screenW * screenH + blockDim - 1) / blockDim;

    traceScene<<<gridDim, blockDim>>>(0, 0, screenW, screenH);

    cudaError_t err = cudaPeekAtLastError();

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to launch vectorAdd kernel (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    cudaThreadSynchronize();
    cudaDeviceSynchronize();




}


void CUDAPathTracer::init()
{
    loadCamera();
    loadPrimitives();
    loadLights();
    createFrameBuffer();
    loadParameters();

    //printInfo<<<1, 1>>>();
    //cudaDeviceSynchronize();

    startRayTracing();

}

void CUDAPathTracer::createFrameBuffer()
{
    cudaError_t err = cudaSuccess;

    screenH = pathTracer->frameBuffer.h;
    screenW = pathTracer->frameBuffer.w;

    err = cudaMalloc((void**)&frameBuffer, 3 * screenW * screenH * sizeof(float));

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed! (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

}

void CUDAPathTracer::loadCamera()
{
    //printf("load camera\n");
    //printf("camera: %p\n", pathTracer->camera);
    GPUCamera tmpCam;
    Camera* cam = pathTracer->camera;
    tmpCam.widthDivDist = cam->screenW / cam->screenDist;
    tmpCam.heightDivDist = cam->screenH / cam->screenDist;
    //printf("after loading camera\n");
    for (int i = 0; i < 9; i++) {
        tmpCam.c2w[i] = cam->c2w(i / 3, i % 3);
    }

    for (int i = 0; i < 3; i++) {
        tmpCam.pos[i] = cam->pos[i];
    }

    cudaError_t err = cudaSuccess;
    //cudaMalloc((void**)&gpu_camera,sizeof(GPUCamera));
    err = cudaMemcpyToSymbol(const_camera, &tmpCam,sizeof(GPUCamera));

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to allocate device vector C (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
}

void CUDAPathTracer::loadPrimitives()
{
    vector<Primitive *> primitives;
    for (SceneObject *obj : pathTracer->scene->objects) {
        const vector<Primitive *> &obj_prims = obj->get_primitives();
        primitives.reserve(primitives.size() + obj_prims.size());
        primitives.insert(primitives.end(), obj_prims.begin(), obj_prims.end());
    }

    int N = primitives.size();
    int types[N];
    int bsdfs[N];
    float positions[9 * N];
    float normals[9 * N];

    primNum = N;

    map<BSDF*, int> BSDFMap;

    for (int i = 0; i < N; i++) {
        types[i] = primitives[i]->getType();
        BSDF* bsdf  = primitives[i]->get_bsdf();

        if (BSDFMap.find(bsdf) == BSDFMap.end()) {
            int index = BSDFMap.size();
            BSDFMap[bsdf] = index;
            bsdfs[i] = index;
        }
        else{
            bsdfs[i] = BSDFMap[bsdf];
        }


        if (types[i] == 0) {
            Vector3D o = ((Sphere*)primitives[i])->o;
            positions[9 * i] = o[0];
            positions[9 * i + 1] = o[1];
            positions[9 * i + 2] = o[2];
            positions[9 * i + 3] = ((Sphere*)primitives[i])->r;
        }
        else{
            const Mesh* mesh = ((Triangle*)primitives[i])->mesh;
            int v1 = ((Triangle*)primitives[i])->v1;
            int v2 = ((Triangle*)primitives[i])->v2;
            int v3 = ((Triangle*)primitives[i])->v3;

            positions[9 * i] = mesh->positions[v1][0];
            positions[9 * i + 1] = mesh->positions[v1][1];
            positions[9 * i + 2] = mesh->positions[v1][2];
            normals[9 * i] = mesh->normals[v1][0];
            normals[9 * i + 1] = mesh->normals[v1][1];
            normals[9 * i + 2] = mesh->normals[v1][2];

            positions[9 * i + 3] = mesh->positions[v2][0];
            positions[9 * i + 4] = mesh->positions[v2][1];
            positions[9 * i + 5] = mesh->positions[v2][2];
            normals[9 * i + 3] = mesh->normals[v2][0];
            normals[9 * i + 4] = mesh->normals[v2][1];
            normals[9 * i + 5] = mesh->normals[v2][2];

            positions[9 * i + 6] = mesh->positions[v3][0];
            positions[9 * i + 7] = mesh->positions[v3][1];
            positions[9 * i + 8] = mesh->positions[v3][2];
            normals[9 * i + 6] = mesh->normals[v3][0];
            normals[9 * i + 7] = mesh->normals[v3][1];
            normals[9 * i + 8] = mesh->normals[v3][2];
        }
    }

    GPUBSDF BSDFArray[BSDFMap.size()];

    for (auto itr = BSDFMap.begin(); itr != BSDFMap.end(); itr++) {
        GPUBSDF& gpu_bsdf = BSDFArray[itr->second];
        BSDF* bsdf = itr->first;
        gpu_bsdf.type = bsdf->getType();

        if (gpu_bsdf.type == 0) {
            Spectrum& albedo = ((DiffuseBSDF*)bsdf)->albedo;
            gpu_bsdf.albedo[0] = albedo.r;
            gpu_bsdf.albedo[1] = albedo.g;
            gpu_bsdf.albedo[2] = albedo.b;
        }
        else if(gpu_bsdf.type == 1){
            Spectrum& reflectance = ((MirrorBSDF*)bsdf)->reflectance;
            gpu_bsdf.reflectance[0] = reflectance.r;
            gpu_bsdf.reflectance[1] = reflectance.g;
            gpu_bsdf.reflectance[2] = reflectance.b;
        }
        else if(gpu_bsdf.type == 2){
            Spectrum& transmittance = ((RefractionBSDF*)bsdf)->transmittance;
            gpu_bsdf.transmittance[0] = transmittance.r;
            gpu_bsdf.transmittance[1] = transmittance.g;
            gpu_bsdf.transmittance[2] = transmittance.b;
            gpu_bsdf.ior = ((RefractionBSDF*)bsdf)->ior;
        }
        else if(gpu_bsdf.type == 3){
            Spectrum& reflectance = ((GlassBSDF*)bsdf)->reflectance;
            gpu_bsdf.reflectance[0] = reflectance.r;
            gpu_bsdf.reflectance[1] = reflectance.g;
            gpu_bsdf.reflectance[2] = reflectance.b;
            Spectrum& transmittance = ((GlassBSDF*)bsdf)->transmittance;
            gpu_bsdf.transmittance[0] = transmittance.r;
            gpu_bsdf.transmittance[1] = transmittance.g;
            gpu_bsdf.transmittance[2] = transmittance.b;
            gpu_bsdf.ior = ((GlassBSDF*)bsdf)->ior;
        }
        else if(gpu_bsdf.type == 4){
            Spectrum& albedo = ((EmissionBSDF*)bsdf)->radiance;
            gpu_bsdf.albedo[0] = albedo.r;
            gpu_bsdf.albedo[1] = albedo.g;
            gpu_bsdf.albedo[2] = albedo.b;

        }
    }

    cudaMalloc((void**)&gpu_types, N * sizeof(int));
    cudaMalloc((void**)&gpu_bsdfIndexes, N * sizeof(int));
    cudaMalloc((void**)&gpu_positions, 9 * N * sizeof(float));
    cudaMalloc((void**)&gpu_normals, 9 * N * sizeof(float));

    cudaMemcpy(gpu_types, types, N * sizeof(int),cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_bsdfIndexes, bsdfs, N * sizeof(int),cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_positions, positions, 9 * N * sizeof(float),cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_normals, normals, 9 * N * sizeof(float),cudaMemcpyHostToDevice);

    //cudaMalloc((void**)&gpu_bsdfs, BSDFMap.size() * sizeof(GPUBSDF));

    cudaError_t err = cudaSuccess;

    err = cudaMemcpyToSymbol(const_bsdfs, BSDFArray, BSDFMap.size() * sizeof(GPUBSDF));

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed! (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

}

// Load light
void CUDAPathTracer::toGPULight(SceneLight* l, GPULight *gpuLight) {
    gpuLight->type = l->getType();
    switch(l->getType()) {
        case 0: // DirectionalLight
        {
            DirectionalLight* light = (DirectionalLight*) l;
            for (int i = 0; i < 3; ++i) {
              gpuLight->radiance[i] = light->radiance[i];
              gpuLight->dirToLight[i] = light->dirToLight[i];
            }
        }
        break;

        case 1: // InfiniteHemisphereLight
        {
            InfiniteHemisphereLight* light = (InfiniteHemisphereLight*) l;
            for (int i = 0; i < 3; ++i) {
                gpuLight->radiance[i] = light->radiance[i];
            }
        }
        break;

        case 2: // PointLight
        {
            PointLight* light = (PointLight*) l;
            for (int i = 0; i < 3; ++i) {
              gpuLight->radiance[i] = light->radiance[i];
              gpuLight->position[i] = light->position[i];
            }
        }
        break;

        case 3: // AreaLight
        {
            AreaLight* light = (AreaLight*) l;
            for (int i = 0; i < 3; ++i) {
              gpuLight->radiance[i] = light->radiance[i];
              gpuLight->position[i] = light->position[i];
              gpuLight->direction[i] = light->direction[i];
              gpuLight->dim_x[i] = light->dim_x[i];
              gpuLight->dim_y[i] = light->dim_y[i];
              gpuLight->area = light->area;
            }
        }
        break;

        default:
        break;
    }
}

void CUDAPathTracer::loadLights() {
    int tmpLightNum = pathTracer->scene->lights.size();

    GPULight tmpLights[tmpLightNum];

    for (int i = 0; i < tmpLightNum; ++i) {
        //displayLight(pathTracer->scene->lights[i]);
        toGPULight(pathTracer->scene->lights[i], tmpLights + i);
    }
    //cudaMalloc((void**)&gpu_lights, sizeof(GPULight) * tmpLightNum);


    cudaError_t err = cudaSuccess;

    err = cudaMemcpyToSymbol(const_lights, tmpLights, sizeof(GPULight) * tmpLightNum);


    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed! (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

//    GPULight rtLights[tmpLightNum];
//    cudaMemcpy(rtLights, gpu_lights, sizeof(GPULight) * tmpLightNum, cudaMemcpyDeviceToHost);
//    //printf("==================\n");
//    for (int i = 0; i < tmpLightNum; ++i)
//    {
//        displayGPULight(rtLights + i);
//    }
}

// load Parameters
void CUDAPathTracer::loadParameters() {
    Parameters tmpParams;
    tmpParams.screenW = pathTracer->frameBuffer.w;
    tmpParams.screenH = pathTracer->frameBuffer.h;
    tmpParams.max_ray_depth = pathTracer->max_ray_depth;
    tmpParams.ns_aa = pathTracer->ns_aa;
    tmpParams.ns_area_light = pathTracer->ns_area_light;
    tmpParams.lightNum = pathTracer->scene->lights.size();
    tmpParams.types = gpu_types;
    tmpParams.bsdfIndexes = gpu_bsdfIndexes;
    tmpParams.positions = gpu_positions;
    tmpParams.normals = gpu_normals;
    tmpParams.primNum = primNum;
    tmpParams.frameBuffer = frameBuffer;

    cudaError_t err = cudaSuccess;

    err = cudaMemcpyToSymbol(const_params, &tmpParams, sizeof(Parameters));

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed! (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
    //Parameters rtParms;
    //cudaMemcpy(&rtParms, parms, sizeof(Parameters), cudaMemcpyDeviceToHost);
    //printf("screenW: %d, screenH: %d, max_ray_depth: %d, ns_aa: %d, ns_area_light: %d, lightNum: %d\n", rtParms.screenW, rtParms.screenH, rtParms.max_ray_depth, rtParms.ns_aa, rtParms.ns_area_light, rtParms.lightNum);
}

void CUDAPathTracer::updateHostSampleBuffer() {
    float* gpuBuffer = (float*) malloc(sizeof(float) * (3 * screenW * screenH));
    cudaError_t err = cudaSuccess;

    err = cudaMemcpy(gpuBuffer, frameBuffer, sizeof(float) * (3 * screenW * screenH), cudaMemcpyDeviceToHost);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed! (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    pathTracer->updateBufferFromGPU(gpuBuffer);
    free(gpuBuffer);
}

void PathTracer::updateBufferFromGPU(float* gpuBuffer) {
    size_t w = sampleBuffer.w;
    size_t h = sampleBuffer.h;
    for (int x = 0; x < w; ++x)
    {
        for (int y = 0; y < h; ++y)
        {
            int index = 3 * (y * w + x);
            Spectrum s(gpuBuffer[index], gpuBuffer[index + 1], gpuBuffer[index + 2]);
            //cout << s.r << "," << s.g << "," << s.b << endl;
            sampleBuffer.update_pixel(s, x, y);
        }
    }
    sampleBuffer.toColor(frameBuffer, 0, 0, w, h);
}


int test(){

	// Error code to check return values for CUDA calls
    cudaError_t err = cudaSuccess;

    // Print the vector length to be used, and compute its size
    int numElements = 50000;
    size_t size = numElements * sizeof(float);
    printf("[Vector addition of %d elements]\n", numElements);

    // Allocate the host input vector A
    float *h_A = (float *)malloc(size);

    // Allocate the host input vector B
    float *h_B = (float *)malloc(size);

    // Allocate the host output vector C
    float *h_C = (float *)malloc(size);

    // Verify that allocations succeeded
    if (h_A == NULL || h_B == NULL || h_C == NULL)
    {
        fprintf(stderr, "Failed to allocate host vectors!\n");
        exit(EXIT_FAILURE);
    }

    // Initialize the host input vectors
    for (int i = 0; i < numElements; ++i)
    {
        h_A[i] = rand()/(float)RAND_MAX;
        h_B[i] = rand()/(float)RAND_MAX;
    }

    // Allocate the device input vector A
    float *d_A = NULL;
    err = cudaMalloc((void **)&d_A, size);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to allocate device vector A (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Allocate the device input vector B
    float *d_B = NULL;
    err = cudaMalloc((void **)&d_B, size);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to allocate device vector B (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Allocate the device output vector C
    float *d_C = NULL;
    err = cudaMalloc((void **)&d_C, size);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to allocate device vector C (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Copy the host input vectors A and B in host memory to the device input vectors in
    // device memory
    printf("Copy input data from the host memory to the CUDA device\n");
    err = cudaMemcpy(d_A, h_A, size, cudaMemcpyHostToDevice);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to copy vector A from host to device (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    err = cudaMemcpy(d_B, h_B, size, cudaMemcpyHostToDevice);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to copy vector B from host to device (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Launch the Vector Add CUDA Kernel
    int threadsPerBlock = 256;
    int blocksPerGrid =(numElements + threadsPerBlock - 1) / threadsPerBlock;
    printf("CUDA kernel launch with %d blocks of %d threads\n", blocksPerGrid, threadsPerBlock);
    vectorAdd<<<blocksPerGrid, threadsPerBlock>>>(d_A, d_B, d_C, numElements);
    err = cudaGetLastError();

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to launch vectorAdd kernel (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Copy the device result vector in device memory to the host result vector
    // in host memory.
    printf("Copy output data from the CUDA device to the host memory\n");
    err = cudaMemcpy(h_C, d_C, size, cudaMemcpyDeviceToHost);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to copy vector C from device to host (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Verify that the result vector is correct
    for (int i = 0; i < numElements; ++i)
    {
        if (fabs(h_A[i] + h_B[i] - h_C[i]) > 1e-5)
        {
            fprintf(stderr, "Result verification failed at element %d!\n", i);
            exit(EXIT_FAILURE);
        }
    }

    printf("Test PASSED! YEAH!!\n");

    // Free device global memory
    err = cudaFree(d_A);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to free device vector A (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    err = cudaFree(d_B);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to free device vector B (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    err = cudaFree(d_C);

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to free device vector C (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    // Free host memory
    free(h_A);
    free(h_B);
    free(h_C);

    // Reset the device and exit
    // cudaDeviceReset causes the driver to clean up all state. While
    // not mandatory in normal operation, it is good practice.  It is also
    // needed to ensure correct operation when the application is being
    // profiled. Calling cudaDeviceReset causes all profile data to be
    // flushed before the application exits
    err = cudaDeviceReset();

    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to deinitialize the device! error=%s\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }

    printf("Done\n");

    return 0;


}
