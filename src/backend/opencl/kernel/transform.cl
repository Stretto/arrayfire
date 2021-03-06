/*******************************************************
 * Copyright (c) 2014, ArrayFire
 * All rights reserved.
 *
 * This file is distributed under 3-clause BSD license.
 * The complete license agreement can be obtained at:
 * http://arrayfire.com/licenses/BSD-3-Clause
 ********************************************************/

#define NEAREST transform_n
#define BILINEAR transform_b
#define LOWER transform_l

void calc_transf_inverse(float* txo, __global const float* txi)
{
#if PERSPECTIVE
    txo[0] =   txi[4]*txi[8] - txi[5]*txi[7];
    txo[1] = -(txi[1]*txi[8] - txi[2]*txi[7]);
    txo[2] =   txi[1]*txi[5] - txi[2]*txi[4];

    txo[3] = -(txi[3]*txi[8] - txi[5]*txi[6]);
    txo[4] =   txi[0]*txi[8] - txi[2]*txi[6];
    txo[5] = -(txi[0]*txi[5] - txi[2]*txi[3]);

    txo[6] =   txi[3]*txi[7] - txi[4]*txi[6];
    txo[7] = -(txi[0]*txi[7] - txi[1]*txi[6]);
    txo[8] =   txi[0]*txi[4] - txi[1]*txi[3];

    float det = txi[0]*txo[0] + txi[1]*txo[3] + txi[2]*txo[6];

    txo[0] /= det; txo[1] /= det; txo[2] /= det;
    txo[3] /= det; txo[4] /= det; txo[5] /= det;
    txo[6] /= det; txo[7] /= det; txo[8] /= det;
#else
    float det = txi[0]*txi[4] - txi[1]*txi[3];

    txo[0] = txi[4] / det;
    txo[1] = txi[3] / det;
    txo[3] = txi[1] / det;
    txo[4] = txi[0] / det;

    txo[2] = txi[2] * -txo[0] + txi[5] * -txo[1];
    txo[5] = txi[2] * -txo[3] + txi[5] * -txo[4];
#endif
}

__kernel
void transform_kernel(__global T *d_out, const KParam out,
                      __global const T *d_in, const KParam in,
                      __global const float *c_tmat, const KParam tf,
                      const int nImg2, const int nImg3,
                      const int nTfs2, const int nTfs3,
                      const int batchImg2,
                      const int blocksXPerImage, const int blocksYPerImage)
{
    // Image Ids
    const int imgId2 = get_group_id(0) / blocksXPerImage;
    const int imgId3 = get_group_id(1) / blocksYPerImage;

    // Block in local image
    const int blockIdx_x = get_group_id(0) - imgId2 * blocksXPerImage;
    const int blockIdx_y = get_group_id(1) - imgId3 * blocksYPerImage;

    // Get thread indices in local image
    const int xx = blockIdx_x * get_local_size(0) + get_local_id(0);
    const int yy = blockIdx_y * get_local_size(1) + get_local_id(1);

    // Image iteration loop count for image batching
    int limages = min(max((int)(out.dims[2] - imgId2 * nImg2), 1), batchImg2);

    if(xx >= out.dims[0] || yy >= out.dims[1])
        return;

    // Index of transform
    const int eTfs2 = max((nTfs2 / nImg2), 1);
    const int eTfs3 = max((nTfs3 / nImg3), 1);

    int t_idx3 = -1;    // init
    int t_idx2 = -1;    // init
    int t_idx2_offset = 0;

    const int blockIdx_z = get_group_id(2);

    if(nTfs3 == 1) {
        t_idx3 = 0;     // Always 0 as only 1 transform defined
    } else {
        if(nTfs3 == nImg3) {
            t_idx3 = imgId3;    // One to one batch with all transforms defined
        } else {
            t_idx3 = blockIdx_z / eTfs2;    // Transform batched, calculate
            t_idx2_offset = t_idx3 * nTfs2;
        }
    }

    if(nTfs2 == 1) {
        t_idx2 = 0;     // Always 0 as only 1 transform defined
    } else {
        if(nTfs2 == nImg2) {
            t_idx2 = imgId2;    // One to one batch with all transforms defined
        } else {
            t_idx2 = blockIdx_z - t_idx2_offset;   // Transform batched, calculate
        }
    }

    // Linear transform index
    const int t_idx = t_idx2 + t_idx3 * nTfs2;

    // Global offset
    int offset = 0;
    d_in += imgId2 * batchImg2 * in.strides[2] + imgId3 * in.strides[3] + in.offset;
    if(nImg2 == nTfs2 || nImg2 > 1) {   // One-to-One or Image on dim2
          offset += imgId2 * batchImg2 * out.strides[2];
    } else {                            // Transform batched on dim2
          offset += t_idx2 * out.strides[2];
    }

    if(nImg3 == nTfs3 || nImg3 > 1) {   // One-to-One or Image on dim3
          offset += imgId3 * out.strides[3];
    } else {                            // Transform batched on dim2
          offset += t_idx3 * out.strides[3];
    }
    d_out += offset;

    // Transform is in global memory.
    // Needs offset to correct transform being processed.
#if PERSPECTIVE
    const int transf_len = 9;
    float tmat[9];
#else
    const int transf_len = 6;
    float tmat[6];
#endif
    __global const float *tmat_ptr = c_tmat + t_idx * transf_len;

    // We expect a inverse transform matrix by default
    // If it is an forward transform, then we need its inverse
    if(INVERSE == 1) {
        #pragma unroll 3
        for(int i = 0; i < transf_len; i++)
            tmat[i] = tmat_ptr[i];
    } else {
        calc_transf_inverse(tmat, tmat_ptr);
    }

    INTERP(d_out, out, d_in, in, tmat, xx, yy, limages);
}
