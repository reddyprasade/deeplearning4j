/* ******************************************************************************
 *
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 *  See the NOTICE file distributed with this work for additional
 *  information regarding copyright ownership.
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 ******************************************************************************/

//
// @author Oleh Semeniv (oleg.semeniv@gmail.com)
//
#include <helpers/PointersManager.h>
#include <math/platformmath.h>
#include <math/templatemath.h>
#include <ops/declarable/helpers/updatersHelpers.h>
#include <system/op_boilerplate.h>

namespace sd {
namespace ops {
namespace helpers {

///////////////////////////////////////////////////////////////////
template <typename T>
SD_KERNEL void nadamUpdaterCuda(const void* vx, const sd::LongType* xShapeInfo, const void* vinv,
                                const sd::LongType* invShapeInfo, const void* vinm, const sd::LongType* inmShapeInfo,
                                void* vz, const sd::LongType* zShapeInfo, void* vstV, const sd::LongType* stvShapeInfo,
                                void* vstM, const sd::LongType* stmShapeInfo, const T lr, const T beta1, const T beta2,
                                const T epsilon, const T iteration) {
  const auto grad = reinterpret_cast<const T*>(vx);
  const auto initV = reinterpret_cast<const T*>(vinv);
  const auto initM = reinterpret_cast<const T*>(vinm);

  auto up = reinterpret_cast<T*>(vz);
  auto stV = reinterpret_cast<T*>(vstV);
  auto stM = reinterpret_cast<T*>(vstM);

  __shared__ sd::LongType xLen;
  __shared__ T mbeta1T, mbeta1, mbeta2;
  __shared__ bool bEWS, bOrdering, bXZsame, bXInUSame, bXStUSame, bXInMSame, bXStMSame;

  if (threadIdx.x == 0) {
    xLen = shape::length(xShapeInfo);

    mbeta1T = 1.0 - sd::math::sd_pow<T, T, T>(beta1, (iteration + 1));
    mbeta1 = (1 - beta1);
    mbeta2 = (1 - beta2);

    bEWS = 1 == shape::elementWiseStride(xShapeInfo) && 1 == shape::elementWiseStride(zShapeInfo) &&
           1 == shape::elementWiseStride(stmShapeInfo) && 1 == shape::elementWiseStride(inmShapeInfo) &&
           1 == shape::elementWiseStride(stvShapeInfo) && 1 == shape::elementWiseStride(invShapeInfo);
    bOrdering = shape::order(xShapeInfo) == shape::order(zShapeInfo) &&
                shape::order(zShapeInfo) == shape::order(stmShapeInfo) &&
                shape::order(stmShapeInfo) == shape::order(inmShapeInfo) &&
                shape::order(inmShapeInfo) == shape::order(stvShapeInfo) &&
                shape::order(stvShapeInfo) == shape::order(invShapeInfo);

    bXZsame = shape::haveSameShapeAndStrides(xShapeInfo, zShapeInfo);
    bXInUSame = shape::haveSameShapeAndStrides(xShapeInfo, invShapeInfo);
    bXStUSame = shape::haveSameShapeAndStrides(xShapeInfo, stvShapeInfo);
    bXInMSame = shape::haveSameShapeAndStrides(xShapeInfo, inmShapeInfo);
    bXStMSame = shape::haveSameShapeAndStrides(xShapeInfo, stmShapeInfo);
  }
  __syncthreads();

  sd::LongType coords[SD_MAX_RANK];

  for (sd::LongType i = blockIdx.x * blockDim.x + threadIdx.x; i < xLen; i += gridDim.x * blockDim.x) {
    auto xOffset = i, zOffset = i, initMOffset = i, initUOffset = i, stMOffset = i, stUOffset = i;

    if (!bEWS || !bOrdering) {
      shape::index2coords(i, xShapeInfo, coords);
      xOffset = shape::getOffset(xShapeInfo, coords);
      zOffset = bXZsame ? xOffset : shape::getOffset(zShapeInfo, coords);
      initUOffset = bXInUSame ? xOffset : shape::getOffset(invShapeInfo, coords);
      stUOffset = bXStUSame ? xOffset : shape::getOffset(stvShapeInfo, coords);
      initMOffset = bXInMSame ? xOffset : shape::getOffset(inmShapeInfo, coords);
      stMOffset = bXStMSame ? xOffset : shape::getOffset(stmShapeInfo, coords);
    }

    auto oneMinusBeta1Grad = grad[xOffset] * mbeta1;

    stM[stMOffset] = beta1 * initM[initMOffset] + oneMinusBeta1Grad;
    stV[stUOffset] = beta2 * initV[initUOffset] + grad[xOffset] * grad[xOffset] * mbeta2;

    up[zOffset] = (lr * ((stM[stMOffset] * beta1 + oneMinusBeta1Grad) / mbeta1T)) /
                  (sd::math::sd_sqrt<T, T>(stV[stUOffset]) + epsilon);
  }
}

///////////////////////////////////////////////////////////////////
template <typename T>
void nadamUpdaterCudaLauncher(const int blocksPerGrid, const int threadsPerBlock, const cudaStream_t* stream,
                              const void* vx, const sd::LongType* xShapeInfo, const void* vinv,
                              const sd::LongType* invShapeInfo, const void* vinm, const sd::LongType* inmShapeInfo,
                              void* vz, const sd::LongType* zShapeInfo, void* vstV, const sd::LongType* stvShapeInfo,
                              void* vstM, const sd::LongType* stmShapeInfo, const double dLr, const double dBeta1,
                              const double dBeta2, const double dEpsilon, const int nIteration) {
  const T lr = static_cast<T>(dLr);
  const T beta1 = static_cast<T>(dBeta1);
  const T beta2 = static_cast<T>(dBeta2);
  const T epsilon = static_cast<T>(dEpsilon);
  const T iteration = static_cast<T>(nIteration);

  nadamUpdaterCuda<T><<<blocksPerGrid, threadsPerBlock, 256, *stream>>>(
      vx, xShapeInfo, vinv, invShapeInfo, vinm, inmShapeInfo, vz, zShapeInfo, vstV, stvShapeInfo, vstM, stmShapeInfo,
      lr, beta1, beta2, epsilon, iteration);
}

///////////////////////////////////////////////////////////////////
void updaterNadam(sd::LaunchContext* context, const NDArray& gradient, const NDArray& initStateV,
                  const NDArray& initStateM, NDArray& update, NDArray& stateV, NDArray& stateM, const double dLr,
                  const double dBeta1, const double dBeta2, const double dEpsilon, const int nIteration) {
  PointersManager manager(context, "nadamUpdater");

  const int threadsPerBlock = SD_MAX_NUM_THREADS / 4;
  const int blocksPerGrid = (gradient.lengthOf() + threadsPerBlock - 1) / threadsPerBlock;

  NDArray::prepareSpecialUse({&update, &stateV, &stateM}, {&gradient, &initStateV, &initStateM});
  BUILD_SINGLE_SELECTOR(gradient.dataType(), nadamUpdaterCudaLauncher,
                        (blocksPerGrid, threadsPerBlock, context->getCudaStream(), gradient.specialBuffer(),
                         gradient.specialShapeInfo(), initStateV.specialBuffer(), initStateV.specialShapeInfo(),
                         initStateM.specialBuffer(), initStateM.specialShapeInfo(), update.specialBuffer(),
                         update.specialShapeInfo(), stateV.specialBuffer(), stateV.specialShapeInfo(),
                         stateM.specialBuffer(), stateM.specialShapeInfo(), dLr, dBeta1, dBeta2, dEpsilon, nIteration),
                        SD_FLOAT_TYPES);
  NDArray::registerSpecialUse({&update, &stateV, &stateM}, {&gradient, &initStateV, &initStateM});

  manager.synchronize();
}

}  // namespace helpers
}  // namespace ops
}  // namespace sd
