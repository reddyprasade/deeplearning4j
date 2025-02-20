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
#include <array/ConstantDataBuffer.h>
#include <array/DataTypeUtils.h>
#include <array/ShapeDescriptor.h>
#include <cuda.h>
#include <exceptions/cuda_exception.h>
#include <exceptions/datatype_exception.h>
#include <helpers/ConstantShapeHelper.h>
#include <helpers/CudaLaunchHelper.h>
#include <helpers/DebugHelper.h>
#include <helpers/PointersManager.h>
#include <helpers/ShapeBuilders.h>
#include <legacy/NativeOpExecutioner.h>
#include <loops/broadcasting.h>
#include <loops/broadcasting_bool.h>
#include <loops/broadcasting_int.h>
#include <loops/indexreduce.h>
#include <loops/pairwise_bool.h>
#include <loops/pairwise_int.h>
#include <loops/pairwise_transform.h>
#include <loops/random.h>
#include <loops/reduce3.h>
#include <loops/reduce_bool.h>
#include <loops/reduce_float.h>
#include <loops/reduce_long.h>
#include <loops/reduce_same.h>
#include <loops/scalar.h>
#include <loops/scalar_bool.h>
#include <loops/scalar_int.h>
#include <loops/special_kernels.h>
#include <loops/summarystatsreduce.h>
#include <loops/transform_any.h>
#include <loops/transform_bool.h>
#include <loops/transform_float.h>
#include <loops/transform_same.h>
#include <loops/transform_strict.h>
#include <system/op_boilerplate.h>

using namespace sd;

/**
 * This is utility kernel, that updates given special buffer with proper values in device memory
 */
extern "C" SD_KERNEL void prepareShapeBuffer(int* dimension, int* maxDimension, sd::LongType* specialPointer, int rows,
                                             sd::DataType dataType) {
  sd::LongType tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid > 0) return;

  dimension[0] = 0;
  maxDimension[0] = 1;

  specialPointer[0] = 2;
  specialPointer[1] = rows;
  specialPointer[2] = 1;
  specialPointer[3] = 1;
  specialPointer[4] = 1;
  specialPointer[5] = 0;
  specialPointer[6] = 1;
  specialPointer[7] = 99;

  ArrayOptions::setDataType(specialPointer, dataType);

  // printf("special[0]: [%lld]\n", (long long) specialPointer[0]);
  // shape::printShapeInfoLinear("prepareShapeBuffer", specialPointer);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execPairwiseTransform(sd::LaunchContext* lc, int opNum, void const* hX,
                                                sd::LongType const* hXShapeInfo, void const* dX,
                                                sd::LongType const* dXShapeInfo, void const* hY,
                                                sd::LongType const* hYShapeInfo, void const* dY,
                                                sd::LongType const* dYShapeInfo, void* hZ,
                                                sd::LongType const* hZShapeInfo, void* dZ,
                                                sd::LongType const* dZShapeInfo, void* extraParams) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  if (xType != zType && yType != zType)
    throw std::runtime_error(
        "NativeOpExecutioner::execPairwiseTransform requires Z operand to have either X or Y type");
  if (lc == nullptr)
    throw std::runtime_error("NativeOpExecutioner::execPairwiseTransform: launch context cannot be nullptr !");
  if (stream == nullptr)
    throw std::runtime_error("NativeOpExecutioner::execPairwiseTransform: CUDA stream cannot be nullptr !");

  dim3 launchDims(256, 1024, 8192);

#ifdef SD_EXPERIMENTAL_ENABLED
  BUILD_PAIRWISE_SELECTOR(
      xType, yType, zType, functions::pairwise_transforms::PairWiseTransform,
      ::executeCudaShaped(launchDims, stream, opType, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams),
      SD_COMMON_TYPES, SD_COMMON_TYPES)
#else
  BUILD_SINGLE_SELECTOR_THRICE(
      xType, functions::pairwise_transforms::PairWiseTransform,
      ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams),
      SD_COMMON_TYPES)
#endif

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execPairwiseTransform failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execPairwiseBoolTransform(sd::LaunchContext* lc, int opNum, void const* hX,
                                                    sd::LongType const* hXShapeInfo, void const* dX,
                                                    sd::LongType const* dXShapeInfo, void const* hY,
                                                    sd::LongType const* hYShapeInfo, void const* dY,
                                                    sd::LongType const* dYShapeInfo, void* hZ,
                                                    sd::LongType const* hZShapeInfo, void* dZ,
                                                    sd::LongType const* dZShapeInfo, void* extraParams) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  if (!DataTypeUtils::isB(zType))
    throw sd::datatype_exception::build("NativeOpExecutioner::execPairwiseBoolTransform wrong Z operand data type",
                                        sd::DataType::BOOL, zType);

  if (yType != xType)
    throw sd::datatype_exception::build(
        "NativeOpExecutioner::execPairwiseBoolTransform both operands must have same data type", xType, yType);

  dim3 launchDims(256, 1024, 16384);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::pairwise_transforms::PairWiseBoolTransform,
      ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams),
      SD_COMMON_TYPES, SD_BOOL_TYPES)

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execPairwiseBoolTransform failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execPairwiseIntTransform(sd::LaunchContext* lc, int opNum, void const* hX,
                                                   sd::LongType const* hXShapeInfo, void const* dX,
                                                   sd::LongType const* dXShapeInfo, void const* hY,
                                                   sd::LongType const* hYShapeInfo, void const* dY,
                                                   sd::LongType const* dYShapeInfo, void* hZ,
                                                   sd::LongType const* hZShapeInfo, void* dZ,
                                                   sd::LongType const* dZShapeInfo, void* extraParams) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  if (!DataTypeUtils::isZ(zType))
    throw sd::datatype_exception::build("NativeOpExecutioner::execPairwiseIntTransform wrong Z operand data type",
                                        sd::DataType::BOOL, zType);

  if (yType != xType || zType != xType)
    throw sd::datatype_exception::build(
        "NativeOpExecutioner::execPairwiseIntTransform both operands must have same data type", xType, yType);

  dim3 launchDims(256, 1024, 16384);

  BUILD_SINGLE_SELECTOR(
      xType, functions::pairwise_transforms::PairWiseIntTransform,
      ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams),
      SD_INTEGER_TYPES)

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execPairwiseIntTransform failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execSummaryStatsScalar(sd::LaunchContext* lc, int opNum, void const* hX,
                                                 sd::LongType const* hXShapeInfo, void const* dX,
                                                 sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                                 sd::LongType const* hZShapeInfo, void* dZ,
                                                 sd::LongType const* dZShapeInfo, bool biasCorrected) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  dim3 launchDims = dim3(256, SD_CUDA_BLOCK_SIZE, 1024);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::summarystats::SummaryStatsReduce,
      ::execSummaryStatsReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams, dZ,
                                     dZShapeInfo, hZShapeInfo, nullptr, nullptr, biasCorrected, reductionPointer),
      SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execSummaryStatsScalar failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execBroadcastBool(sd::LaunchContext* lc, int opNum, void const* hX,
                                            sd::LongType const* hXShapeInfo, void const* dX,
                                            sd::LongType const* dXShapeInfo, void const* hY,
                                            sd::LongType const* hYShapeInfo, void const* dY,
                                            sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                            void* dZ, sd::LongType const* dZShapeInfo, void* extraParams,
                                            sd::LongType* dimension, int dimensionLength, sd::LongType const* tadOnlyShapeInfo,
                                            sd::LongType const* tadOffsets, sd::LongType const* tadOnlyShapeInfoZ,
                                            sd::LongType const* tadOffsetsZ) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  if (!DataTypeUtils::isB(zType))
    throw std::runtime_error("NativeOpExecutioner::execBroadcastBool requires Z operand to have BOOL type");

  if (yType != xType)
    throw std::runtime_error("NativeOpExecutioner::execBroadcastBool requires both X & Y operands to have same type");

  if (sd::Environment::getInstance().isDebugAndVerbose()) printf("F3B opType:[%i]\n", opNum);

  dim3 launchDims(256, 256, 1024);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::broadcast::BroadcastBool,
      ::execBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams,
                      dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ),
      SD_COMMON_TYPES, SD_BOOL_TYPES)

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execBroadcastBool failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execBroadcastBool(sd::LaunchContext* lc, const int opNum, const void* hX,
                                            const sd::LongType* hXShapeInfo, const void* dX,
                                            const sd::LongType* dXShapeInfo, const void* hY,
                                            const sd::LongType* hYShapeInfo, const void* dY,
                                            const sd::LongType* dYShapeInfo, void* hZ, const sd::LongType* hZShapeInfo,
                                            void* dZ, const sd::LongType* dZShapeInfo, void* extraParams) {
  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  dim3 launchDims;

  launchDims.y = SD_MAX_NUM_THREADS / 4;                                          // threadsPerBlock
  launchDims.x = (shape::length(hZShapeInfo) + launchDims.y - 1) / launchDims.y;  // blocksPerGrid
  launchDims.z = 1024;                                                            // shared memory

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::broadcast::BroadcastBool,
      ::execBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams),
      SD_COMMON_TYPES, SD_BOOL_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execBroadcastBool failed", res);
}

void NativeOpExecutioner::execInverseBroadcastBool(
    sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo, void const* dX,
    sd::LongType const* dXShapeInfo, void const* hY, sd::LongType const* hYShapeInfo, void const* dY,
    sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo, void* dZ,
    sd::LongType const* dZShapeInfo, void* extraParams, sd::LongType* dimension, int dimensionLength,
    sd::LongType const* tadOnlyShapeInfo, sd::LongType const* tadOffsets, sd::LongType const* tadOnlyShapeInfoZ,
    sd::LongType const* tadOffsetsZ) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  if (!DataTypeUtils::isB(zType))
    throw std::runtime_error("NativeOpExecutioner::execBroadcastBool requires Z operand to have BOOL type");

  if (yType != xType)
    throw std::runtime_error("NativeOpExecutioner::execBroadcastBool requires both X & Y operands to have same type");

  dim3 launchDims(256, 256, 1024);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::broadcast::BroadcastBool,
      ::execInverseBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams,
                             dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ),
      SD_COMMON_TYPES, SD_BOOL_TYPES)

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execInverseBroadcastBool failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execBroadcastInt(
    sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo, void const* dX,
    sd::LongType const* dXShapeInfo, void const* hY, sd::LongType const* hYShapeInfo, void const* dY,
    sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo, void* dZ,
    sd::LongType const* dZShapeInfo, sd::LongType* dimension, int dimensionLength, sd::LongType const* tadOnlyShapeInfo,
    sd::LongType const* tadOffsets, sd::LongType const* tadOnlyShapeInfoZ, sd::LongType const* tadOffsetsZ) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  if (!DataTypeUtils::isZ(zType))
    throw std::runtime_error("NativeOpExecutioner::execBroadcastInt requires Z operand to have INT type");

  if (yType != xType || zType != xType)
    throw std::runtime_error("NativeOpExecutioner::execBroadcastInt requires both X & Y operands to have same type");

  dim3 launchDims(256, 256, 1024);

  BUILD_SINGLE_SELECTOR(
      xType, functions::broadcast::BroadcastInt,
      ::execBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension,
                      dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ),
      SD_INTEGER_TYPES)

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execBroadcastBool failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execBroadcastInt(sd::LaunchContext* lc, const int opNum, const void* hX,
                                           const sd::LongType* hXShapeInfo, const void* dX,
                                           const sd::LongType* dXShapeInfo, const void* hY,
                                           const sd::LongType* hYShapeInfo, const void* dY,
                                           const sd::LongType* dYShapeInfo, void* hZ, const sd::LongType* hZShapeInfo,
                                           void* dZ, const sd::LongType* dZShapeInfo) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  if (!DataTypeUtils::isZ(zType))
    throw std::runtime_error("NativeOpExecutioner::execBroadcastInt requires Z operand to have INT type");

  if (yType != xType || zType != xType)
    throw std::runtime_error("NativeOpExecutioner::execBroadcastInt requires both X & Y operands to have same type");

  dim3 launchDims;

  launchDims.y = SD_MAX_NUM_THREADS / 4;                                          // threadsPerBlock
  launchDims.x = (shape::length(hZShapeInfo) + launchDims.y - 1) / launchDims.y;  // blocksPerGrid
  launchDims.z = 1024;                                                            // shared memory

  BUILD_SINGLE_SELECTOR(xType, functions::broadcast::BroadcastInt,
                        ::execBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo),
                        SD_INTEGER_TYPES)

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execBroadcastBool failed", res);
}

void NativeOpExecutioner::execInverseBroadcastInt(
    sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo, void const* dX,
    sd::LongType const* dXShapeInfo, void const* hY, sd::LongType const* hYShapeInfo, void const* dY,
    sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo, void* dZ,
    sd::LongType const* dZShapeInfo, sd::LongType* dimension, int dimensionLength, sd::LongType const* tadOnlyShapeInfo,
    sd::LongType const* tadOffsets, sd::LongType const* tadOnlyShapeInfoZ, sd::LongType const* tadOffsetsZ) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  if (!DataTypeUtils::isZ(zType))
    throw std::runtime_error("NativeOpExecutioner::execBroadcastInt requires Z operand to have INT type");

  if (yType != xType || zType != xType)
    throw std::runtime_error("NativeOpExecutioner::execBroadcastInt requires both X & Y operands to have same type");

  if (sd::Environment::getInstance().isDebugAndVerbose()) printf("F3BI opType:[%i]\n", opNum);

  dim3 launchDims(256, 256, 1024);

  BUILD_SINGLE_SELECTOR(
      xType, functions::broadcast::BroadcastInt,
      ::execInverseBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension,
                             dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ),
      SD_INTEGER_TYPES)

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execInverseBroadcastInt failed", res);
}

////////////////////////////////////////////////////////////////////////
/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param dY
 * @param dYShapeInfo
 * @param dZ
 * @param dZShapeInfo
 * @param dimension
 * @param dimensionLength
 */
void NativeOpExecutioner::execBroadcast(sd::LaunchContext* lc, int opNum, void const* hX,
                                        sd::LongType const* hXShapeInfo, void const* dX,
                                        sd::LongType const* dXShapeInfo, void const* hY,
                                        sd::LongType const* hYShapeInfo, void const* dY,
                                        sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                        void* dZ, sd::LongType const* dZShapeInfo, sd::LongType* dimension, int dimensionLength,
                                        sd::LongType const* tadOnlyShapeInfo, sd::LongType const* tadOffsets,
                                        sd::LongType const* tadOnlyShapeInfoZ, sd::LongType const* tadOffsetsZ) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  dim3 launchDims(256, 256, 1024);

#ifdef SD_EXPERIMENTAL_ENABLED
  BUILD_PAIRWISE_SELECTOR(
      xType, yType, zType, functions::broadcast::Broadcast,
      ::execBroadcast(launchDims, stream, opType, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension,
                      dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ),
      SD_COMMON_TYPES, SD_COMMON_TYPES);
#else
  BUILD_SINGLE_SELECTOR_THRICE(
      xType, functions::broadcast::Broadcast,
      ::execBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension,
                      dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ),
      SD_COMMON_TYPES);
#endif

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execBroadcast failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execBroadcast(sd::LaunchContext* lc, const int opNum, const void* hX,
                                        const sd::LongType* hXShapeInfo, const void* dX,
                                        const sd::LongType* dXShapeInfo, const void* hY,
                                        const sd::LongType* hYShapeInfo, const void* dY,
                                        const sd::LongType* dYShapeInfo, void* hZ, const sd::LongType* hZShapeInfo,
                                        void* dZ, const sd::LongType* dZShapeInfo) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  dim3 launchDims;

  launchDims.y = SD_MAX_NUM_THREADS / 4;                                          // threadsPerBlock
  launchDims.x = (shape::length(hZShapeInfo) + launchDims.y - 1) / launchDims.y;  // blocksPerGrid
  launchDims.z = 1024;                                                            // shared memory

#ifdef SD_EXPERIMENTAL_ENABLED
  BUILD_PAIRWISE_SELECTOR(xType, yType, zType, functions::broadcast::Broadcast,
                          ::execBroadcast(launchDims, stream, opType, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo),
                          SD_COMMON_TYPES, SD_COMMON_TYPES);
#else
  BUILD_SINGLE_SELECTOR_THRICE(
      xType, functions::broadcast::Broadcast,
      ::execBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo), SD_COMMON_TYPES);
#endif

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execBroadcast failed", res);
}

void NativeOpExecutioner::execInverseBroadcast(
    sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo, void const* dX,
    sd::LongType const* dXShapeInfo, void const* hY, sd::LongType const* hYShapeInfo, void const* dY,
    sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo, void* dZ,
    sd::LongType const* dZShapeInfo, sd::LongType* dimension, int dimensionLength, sd::LongType const* tadOnlyShapeInfo,
    sd::LongType const* tadOffsets, sd::LongType const* tadOnlyShapeInfoZ, sd::LongType const* tadOffsetsZ) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hYShapeInfo)) return;

  dim3 launchDims(256, 256, 1024);

#ifdef SD_EXPERIMENTAL_ENABLED
  BUILD_PAIRWISE_SELECTOR(
      xType, yType, zType, functions::broadcast::Broadcast,
      ::execInverseBroadcast(launchDims, stream, opType, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension,
                             dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ),
      SD_COMMON_TYPES, SD_COMMON_TYPES);
#else
  BUILD_SINGLE_SELECTOR_THRICE(
      xType, functions::broadcast::Broadcast,
      ::execInverseBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension,
                             dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ),
      SD_COMMON_TYPES);
#endif

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execInverseBroadcast failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceSame(sd::LaunchContext* lc, int opNum, void const* hX,
                                         sd::LongType const* hXShapeInfo, void const* dX,
                                         sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                         sd::LongType const* hZShapeInfo, void* dZ, sd::LongType const* dZShapeInfo,
                                         sd::LongType* dimension, int dimensionLength) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  if (sd::Environment::getInstance().isDebugAndVerbose()) printf("SF7 opType:[%i]\n", opNum);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (zType != xType)
    throw datatype_exception::build(
        "NativeOpExecutioner::execReduceSame requires both X & Z operands to have same type", xType, zType);

  auto numBlocks = shape::length(hZShapeInfo);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, SD_CUDA_BLOCK_SIZE, 1024);

  BUILD_SINGLE_SELECTOR(xType, functions::reduce::ReduceSameFunction,
                        ::execReduceXD(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams,
                                       reductionPointer, dZ, dZShapeInfo, hZShapeInfo, dimension),
                        SD_COMMON_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduceSame failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceLong(sd::LaunchContext* lc, int opNum, void const* hX,
                                         sd::LongType const* hXShapeInfo, void const* dX,
                                         sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                         sd::LongType const* hZShapeInfo, void* dZ, sd::LongType const* dZShapeInfo,
                                         sd::LongType* dimension, int dimensionLength) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  if (sd::Environment::getInstance().isDebugAndVerbose()) printf("LF7 opType:[%i]\n", opNum);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (zType != sd::DataType::INT64)
    throw datatype_exception::build("NativeOpExecutioner::execReduceLong wrong Z data type", sd::DataType::INT64,
                                    zType);

  auto numBlocks = shape::length(hZShapeInfo);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, SD_CUDA_BLOCK_SIZE, 1024);

  BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceLongFunction,
                        ::execReduceXD(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams,
                                       reductionPointer, dZ, dZShapeInfo, hZShapeInfo, dimension),
                        SD_COMMON_TYPES, SD_LONG_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduceLong failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceBool(sd::LaunchContext* lc, int opNum, void const* hX,
                                         sd::LongType const* hXShapeInfo, void const* dX,
                                         sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                         sd::LongType const* hZShapeInfo, void* dZ, sd::LongType const* dZShapeInfo,
                                         sd::LongType* dimension, int dimensionLength) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  if (sd::Environment::getInstance().isDebugAndVerbose()) printf("BF7 opType:[%i]\n", opNum);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (zType != sd::DataType::BOOL)
    throw std::runtime_error("NativeOpExecutioner::execReduceBool requires Z operand to have BOOL type");

  auto numBlocks = shape::length(hZShapeInfo);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, SD_CUDA_BLOCK_SIZE, 1024);

  BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceBoolFunction,
                        ::execReduceXD(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams,
                                       reductionPointer, dZ, dZShapeInfo, hZShapeInfo, dimension),
                        SD_COMMON_TYPES, SD_BOOL_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduceBool failed", res);
}

////////////////////////////////////////////////////////////////////////
/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 * @param dZ
 * @param dZShapeInfo
 */
void NativeOpExecutioner::execReduceFloat(sd::LaunchContext* lc, int opNum, const void* hX,
                                          const sd::LongType* hXShapeInfo, const void* dX,
                                          const sd::LongType* dXShapeInfo, void* extraParams, void* hZ,
                                          const sd::LongType* hZShapeInfo, void* dZ, const sd::LongType* dZShapeInfo,
                                          sd::LongType* dimension, int dimensionLength) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  if (sd::Environment::getInstance().isDebugAndVerbose()) printf("F8 opType:[%i]\n", opNum);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  auto numBlocks = shape::length(hZShapeInfo);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, 256, 32768);

  BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceFloatFunction,
                        ::execReduceXD(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams,
                                       reductionPointer, dZ, dZShapeInfo, hZShapeInfo, dimension),
                        SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduceFloat failed", res);
}

////////////////////////////////////////////////////////////////////////
/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 * @param dZ
 * @param dZShapeInfo
 * @param dimension
 * @param dimensionLength
 */
void NativeOpExecutioner::execIndexReduce(sd::LaunchContext* lc, int opNum, void const* hX,
                                          sd::LongType const* hXShapeInfo, void const* dX,
                                          sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                          sd::LongType const* hZShapeInfo, void* dZ, sd::LongType const* dZShapeInfo,
                                          sd::LongType* dimension, int dimensionLength, sd::LongType const* tadShapeInfo,
                                          sd::LongType const* tadOffsets) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();
  auto allocationPointer = lc->getAllocationPointer();

  if (sd::Environment::getInstance().isDebugAndVerbose()) printf("F2 opType:[%i]\n", opNum);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);
  auto numBlocks = shape::length(hZShapeInfo);
  auto tadLength = shape::length(hXShapeInfo) / numBlocks;
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, tadLength < SD_CUDA_BLOCK_SIZE ? tadLength : SD_CUDA_BLOCK_SIZE,
                  1024);

  if (zType != sd::DataType::INT64 && zType != sd::DataType::INT32)
    throw datatype_exception::build("NativeOpExecutioner::execIndexReduce requires Z operand to have INT32/INT64 type",
                                    zType);

  auto dz = reinterpret_cast<sd::LongType*>(dZ);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::indexreduce::IndexReduce,
      ::executeIndexReduce(launchDims, stream, opNum, dX, dXShapeInfo, shape::rank(hXShapeInfo), extraParams, dz,
                           dZShapeInfo, shape::rank(hZShapeInfo), dimension, dimensionLength, 1, allocationPointer,
                           reductionPointer, tadShapeInfo, tadOffsets),
      SD_COMMON_TYPES, SD_INDEXING_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execIndexReduce failed", res);
}

/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 */
////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execIndexReduceScalar(sd::LaunchContext* lc, int opNum, void const* hX,
                                                sd::LongType const* hXShapeInfo, void const* dX,
                                                sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                                sd::LongType const* hZShapeInfo, void* dZ,
                                                sd::LongType const* dZShapeInfo) {
  if (sd::Environment::getInstance().isDebug()) printf("F1 opType:[%i]\n", opNum);

  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();
  auto allocationPointer = lc->getAllocationPointer();

  auto xLength = shape::length(hXShapeInfo);
  auto blockWidth = 256;
  auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, SD_CUDA_BLOCK_SIZE, 1024);

  if (sd::Environment::getInstance().isDebugAndVerbose() && launchDims.x == 1) printf("AF1 opType:[%i]\n", opNum);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  // FIXME: we want Z to be one of integer types
  // if (!DataTypeUtils::isZ(zType))
  //    throw sd::datatype_exception("NativeOpExecutioner::execIndexReduceScalar requires Z operand to have one of
  //    integer types")
  if (zType != sd::DataType::INT64 && zType != sd::DataType::INT32)
    throw sd::datatype_exception::build(
        "NativeOpExecutioner::execIndexReduceScalar requires Z operand to have INT32/INT64 data type", zType);

  auto dz = reinterpret_cast<sd::LongType*>(dZ);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::indexreduce::IndexReduce,
      ::executeIndexReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, shape::rank(hXShapeInfo), extraParams, dz,
                                 dZShapeInfo, 0, nullptr, 0, 1, allocationPointer, reductionPointer, nullptr, nullptr),
      SD_COMMON_TYPES, SD_INDEXING_TYPES);
  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execIndexReduceScalar failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceFloatScalar(sd::LaunchContext* lc, int opNum, void const* hX,
                                                sd::LongType const* hXShapeInfo, void const* dX,
                                                sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                                sd::LongType const* hZShapeInfo, void* dZ,
                                                sd::LongType const* dZShapeInfo) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  auto xLength = shape::length(hXShapeInfo);
  auto blockWidth = 256;
  auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, SD_CUDA_BLOCK_SIZE, 1024);

  BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceFloatFunction,
                        ::execReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams, dZ,
                                           dZShapeInfo, hZShapeInfo, nullptr, 0, reductionPointer, nullptr),
                        SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduceFloatScalar failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceBoolScalar(sd::LaunchContext* lc, int opNum, void const* hX,
                                               sd::LongType const* hXShapeInfo, void const* dX,
                                               sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                               sd::LongType const* hZShapeInfo, void* dZ,
                                               sd::LongType const* dZShapeInfo) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (zType != sd::DataType::BOOL)
    throw std::runtime_error("NativeOpExecutioner::execReduceBoolScalar requires Z operand to have BOOL type");

  auto xLength = shape::length(hXShapeInfo);
  auto blockWidth = SD_CUDA_BLOCK_SIZE;
  auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, blockWidth, 1024);

  BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceBoolFunction,
                        ::execReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams, dZ,
                                           dZShapeInfo, hZShapeInfo, nullptr, 0, reductionPointer, nullptr),
                        SD_COMMON_TYPES, SD_BOOL_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduceBoolScalar failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceSameScalar(sd::LaunchContext* lc, int opNum, void const* hX,
                                               sd::LongType const* hXShapeInfo, void const* dX,
                                               sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                               sd::LongType const* hZShapeInfo, void* dZ,
                                               sd::LongType const* dZShapeInfo) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (zType != xType)
    throw datatype_exception::build(
        "NativeOpExecutioner::execReduceSameScalar requires both X & Z operands to have same type", xType, zType);

  auto xLength = shape::length(hXShapeInfo);
  auto blockWidth = SD_CUDA_BLOCK_SIZE;
  auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, blockWidth, 1024);

  BUILD_SINGLE_SELECTOR(xType, functions::reduce::ReduceSameFunction,
                        ::execReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams, dZ,
                                           dZShapeInfo, hZShapeInfo, nullptr, 0, reductionPointer, nullptr),
                        SD_COMMON_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduceSameScalar failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceLongScalar(sd::LaunchContext* lc, int opNum, void const* hX,
                                               sd::LongType const* hXShapeInfo, void const* dX,
                                               sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                               sd::LongType const* hZShapeInfo, void* dZ,
                                               sd::LongType const* dZShapeInfo) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (zType != sd::DataType::INT64)
    throw datatype_exception::build("NativeOpExecutioner::execReduceLongScalar wrong Z data type", sd::DataType::INT64,
                                    zType);

  auto xLength = shape::length(hXShapeInfo);
  auto blockWidth = SD_CUDA_BLOCK_SIZE;
  auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, blockWidth, 1024);

  BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceLongFunction,
                        ::execReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams, dZ,
                                           dZShapeInfo, hZShapeInfo, nullptr, 0, reductionPointer, nullptr),
                        SD_COMMON_TYPES, SD_LONG_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduceLongScalar failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformSame(sd::LaunchContext* lc, int opNum, void const* hX,
                                            sd::LongType const* hXShapeInfo, void const* dX,
                                            sd::LongType const* dXShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                            void* dZ, sd::LongType const* dZShapeInfo, void* extraParams,
                                            sd::LongType const* tadShapeInfo, sd::LongType const* tadOffsets) {
  auto stream = lc->getCudaStream();

  auto xRank = shape::rank(hXShapeInfo);
  auto zRank = shape::rank(hZShapeInfo);
  auto xType = ArrayOptions::dataType(hXShapeInfo);
  auto zType = ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo)) {
    return;
  }

  if (xType != zType) {
    throw std::runtime_error("NativeOpExecutioner::execTransformSame requires X & Z to have same type");
  }

  dim3 launchDims(512, 512, 16384);
  BUILD_SINGLE_SELECTOR(xType, functions::transform::TransformSame,
                        ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ,
                                                 dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr),
                        SD_COMMON_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execTransformSame failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformBool(sd::LaunchContext* lc, int opNum, void const* hX,
                                            sd::LongType const* hXShapeInfo, void const* dX,
                                            sd::LongType const* dXShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                            void* dZ, sd::LongType const* dZShapeInfo, void* extraParams,
                                            sd::LongType const* tadShapeInfo, sd::LongType const* tadOffsets) {
  auto stream = lc->getCudaStream();

  auto xRank = shape::rank(hXShapeInfo);
  auto zRank = shape::rank(hZShapeInfo);
  auto xType = ArrayOptions::dataType(hXShapeInfo);
  auto zType = ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo)) {
    return;
  }

  if (!DataTypeUtils::isB(zType)) {
    throw std::runtime_error("NativeOpExecutioner::execTransformBool requires Z to have same boolean type");
  }

  dim3 launchDims(512, 512, 16384);
  BUILD_DOUBLE_SELECTOR(xType, zType, functions::transform::TransformBool,
                        ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ,
                                                 dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr),
                        SD_COMMON_TYPES, SD_BOOL_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execTransformBool failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformAny(sd::LaunchContext* lc, int opNum, void const* hX,
                                           sd::LongType const* hXShapeInfo, void const* dX,
                                           sd::LongType const* dXShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                           void* dZ, sd::LongType const* dZShapeInfo, void* extraParams,
                                           sd::LongType const* tadShapeInfo, sd::LongType const* tadOffsets,
                                           bool allowParallelism) {
  auto stream = lc->getCudaStream();

  auto xRank = shape::rank(hXShapeInfo);
  auto zRank = shape::rank(hZShapeInfo);
  auto xType = ArrayOptions::dataType(hXShapeInfo);
  auto zType = ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo)) return;

  if (opNum == sd::transform::Assign && shape::order(hXShapeInfo) == shape::order(hZShapeInfo) &&
      shape::order(hXShapeInfo) == 'c' && xType == zType && shape::elementWiseStride(hXShapeInfo) == 1 &&
      shape::elementWiseStride(hZShapeInfo) == 1) {
    cudaMemcpyAsync(dZ, dX, shape::length(hXShapeInfo) * sd::DataTypeUtils::sizeOfElement(xType),
                    cudaMemcpyDeviceToDevice, *stream);
  } else {
    dim3 launchDims(512, 512, 2048);
    BUILD_DOUBLE_SELECTOR(xType, zType, functions::transform::TransformAny,
                          ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ,
                                                   dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr),
                          SD_COMMON_TYPES, SD_COMMON_TYPES);
  }

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execTransformAny failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformStrict(sd::LaunchContext* lc, int opNum, void const* hX,
                                              sd::LongType const* hXShapeInfo, void const* dX,
                                              sd::LongType const* dXShapeInfo, void* hZ,
                                              sd::LongType const* hZShapeInfo, void* dZ,
                                              sd::LongType const* dZShapeInfo, void* extraParams,
                                              sd::LongType const* tadShapeInfo, sd::LongType const* tadOffsets) {
  auto stream = lc->getCudaStream();

  auto xRank = shape::rank(hXShapeInfo);
  auto zRank = shape::rank(hZShapeInfo);
  auto xType = ArrayOptions::dataType(hXShapeInfo);
  auto zType = ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo)) {
    return;
  }

  if (xType != zType || !DataTypeUtils::isR(xType)) {
    throw datatype_exception::build(
        "NativeOpExecutioner::execTransformStrict requires X & Z to have same floating point type", xType, zType);
  }

  dim3 launchDims(512, 512, 16384);
  BUILD_SINGLE_SELECTOR(xType, functions::transform::TransformStrict,
                        ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ,
                                                 dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr),
                        SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execTransformStrict failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformFloat(sd::LaunchContext* lc, int opNum, void const* hX,
                                             sd::LongType const* hXShapeInfo, void const* dX,
                                             sd::LongType const* dXShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                             void* dZ, sd::LongType const* dZShapeInfo, void* extraParams,
                                             sd::LongType const* tadShapeInfo, sd::LongType const* tadOffsets) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  auto xRank = shape::rank(hXShapeInfo);
  auto zRank = shape::rank(hZShapeInfo);
  auto xType = ArrayOptions::dataType(hXShapeInfo);
  auto zType = ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo)) return;

  if (!DataTypeUtils::isR(zType))
    throw datatype_exception::build("NativeOpExecutioner::execTransformFloat requires Z to have floating point type",
                                    zType);

  dim3 launchDims(512, 512, 2048);
  BUILD_DOUBLE_SELECTOR(xType, zType, functions::transform::TransformFloat,
                        ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ,
                                                 dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr),
                        SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execTransformFloat failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execSummaryStats(sd::LaunchContext* lc, int opNum, void const* hX,
                                           sd::LongType const* hXShapeInfo, void const* dX,
                                           sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                           sd::LongType const* hZShapeInfo, void* dZ, sd::LongType const* dZShapeInfo,
                                           bool biasCorrected) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  dim3 launchDims = dim3(256, SD_CUDA_BLOCK_SIZE, 1024);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (!DataTypeUtils::isR(zType))
    throw sd::datatype_exception::build(
        "NativeOpExecutioner::execSummaryStats requires Z operand to have floating point data type", zType);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::summarystats::SummaryStatsReduce,
      ::execSummaryStatsReduce(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams, dZ, dZShapeInfo,
                               hZShapeInfo, nullptr, nullptr, biasCorrected, reductionPointer),
      SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execSummaryStats A failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execSummaryStats(sd::LaunchContext* lc, int opNum, void const* hX,
                                           sd::LongType const* hXShapeInfo, void const* dX,
                                           sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                           sd::LongType const* hZShapeInfo, void* dZ, sd::LongType const* dZShapeInfo,
                                           sd::LongType* dimension, int dimensionLength, sd::LongType const* tadShapeInfo,
                                           sd::LongType const* tadOffsets, bool biasCorrected) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();

  dim3 launchDims = dim3(256, SD_CUDA_BLOCK_SIZE, 1024);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (!DataTypeUtils::isR(zType))
    throw sd::datatype_exception::build(
        "NativeOpExecutioner::execSummaryStats requires Z operand to have floating point data type", zType);

  BUILD_DOUBLE_SELECTOR(xType, zType, functions::summarystats::SummaryStatsReduce,
                        ::execSummaryStatsReduce(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams,
                                                 dZ, dZShapeInfo, hZShapeInfo, dimension, dimensionLength, tadShapeInfo,
                                                 tadOffsets, biasCorrected, reductionPointer),
                        SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execSummaryStats B failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3(sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo,
                                      void const* dX, sd::LongType const* dXShapeInfo, void* extraParams,
                                      void const* hY, sd::LongType const* hYShapeInfo, void const* dY,
                                      sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                      void* dZ, sd::LongType const* dZShapeInfo) {
  auto stream = lc->getCudaStream();
  auto reductionPointer = lc->getReductionPointer();
  auto allocationPointer = lc->getAllocationPointer();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  auto blockWidth = SD_CUDA_BLOCK_SIZE;
  auto numBlocks = CudaLaunchHelper::getReductionBlocks(shape::length(hXShapeInfo), blockWidth);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, blockWidth, 1024);

  if (xType != yType)
    throw sd::datatype_exception::build("NativeOpExecutioner::execReduce3 requires Y operand to have X type", xType,
                                        yType);

  if (!DataTypeUtils::isR(zType))
    throw sd::datatype_exception::build(
        "NativeOpExecutioner::execReduce3 requires Z operand to have floating point data type", zType);

  BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce3::Reduce3,
                        ::execScalar(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, extraParams, dZ,
                                     dZShapeInfo, allocationPointer, reductionPointer, nullptr),
                        SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduce3 failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3(sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo,
                                      void const* dX, sd::LongType const* dXShapeInfo, void* extraParams,
                                      void const* hY, sd::LongType const* hYShapeInfo, void const* dY,
                                      sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                      void* dZ, sd::LongType const* dZShapeInfo, sd::LongType* dimension, int dimensionLength,
                                      sd::LongType const* tadOnlyShapeInfo, sd::LongType const* tadOffsets,
                                      sd::LongType const* yTadOnlyShapeInfo, sd::LongType const* yTadOffsets) {
  if (shape::isScalar(hZShapeInfo)) {
    NativeOpExecutioner::execReduce3(lc, opNum, hX, hXShapeInfo, dX, dXShapeInfo, extraParams, hY, hYShapeInfo, dY,
                                     dYShapeInfo, hZ, hZShapeInfo, dZ, dZShapeInfo);
    return;
  }

  auto stream = lc->getCudaStream();
  auto allocationPointer = lc->getAllocationPointer();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (xType != yType)
    throw sd::datatype_exception::build("NativeOpExecutioner::execReduce3 requires Y operand to have X type", xType,
                                        yType);

  if (!DataTypeUtils::isR(zType))
    throw sd::datatype_exception::build(
        "NativeOpExecutioner::execReduce3 requires Z operand to have floating point data type", zType);

  auto numBlocks = shape::length(hZShapeInfo);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, SD_CUDA_BLOCK_SIZE, 1024);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::reduce3::Reduce3,
      ::exec(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, extraParams, dZ, dZShapeInfo, dimension,
             dimensionLength, 1, allocationPointer, tadOnlyShapeInfo, tadOffsets, yTadOnlyShapeInfo, yTadOffsets),
      SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduce3 B failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3Scalar(sd::LaunchContext* lc, int opNum, void const* hX,
                                            sd::LongType const* hXShapeInfo, void const* dX,
                                            sd::LongType const* dXShapeInfo, void* extraParams, void const* hY,
                                            sd::LongType const* hYShapeInfo, void const* dY,
                                            sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                            void* dZ, sd::LongType const* dZShapeInfo) {
  auto stream = lc->getCudaStream();
  auto allocationPointer = lc->getAllocationPointer();
  auto reductionPointer = lc->getReductionPointer();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  auto xLength = shape::length(hXShapeInfo);
  auto blockWidth = SD_CUDA_BLOCK_SIZE;
  auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, blockWidth, 1024);

  if (xType != yType)
    throw sd::datatype_exception::build("NativeOpExecutioner::execReduce3Scalar requires Y operand to have X type",
                                        xType, yType);

  if (!DataTypeUtils::isR(zType))
    throw sd::datatype_exception::build(
        "NativeOpExecutioner::execReduce3Scalar requires Z operand to have floating point data type", zType);

  BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce3::Reduce3,
                        ::execScalar(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, extraParams, dZ,
                                     dZShapeInfo, allocationPointer, reductionPointer, nullptr),
                        SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduce3Scalar failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalarBool(sd::LaunchContext* lc, int opNum, void const* hX,
                                         sd::LongType const* hXShapeInfo, void const* dX,
                                         sd::LongType const* dXShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                         void* dZ, sd::LongType const* dZShapeInfo, void const* hScalar,
                                         sd::LongType const* hScalarShapeInfo, void const* dScalar,
                                         sd::LongType const* dScalarShapeInfo, void* extraParams,
                                         bool allowParallelism) {
  auto stream = lc->getCudaStream();

  dim3 launchDims = dim3(256, 512, 8192);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hScalarShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hScalarShapeInfo)) return;

  if (xType != yType) throw std::runtime_error("NativeOpExecutioner::execScalarBool requires X & Y to have same type");

  if (!DataTypeUtils::isB(zType))
    throw std::runtime_error("NativeOpExecutioner::execScalarBool requires Z operand to have BOOL type");

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::scalar::ScalarBoolTransform,
      ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalar, extraParams),
      SD_COMMON_TYPES, SD_BOOL_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execScalarBool failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalarBool(
    sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo, void const* dX,
    sd::LongType const* dXShapeInfo, void* extraParams, void* hZ, sd::LongType const* hZShapeInfo, void* dZ,
    sd::LongType const* dZShapeInfo, void const* hScalars, sd::LongType const* hScalarShapeInfo, void const* dScalars,
    sd::LongType const* dScalarShapeInfo, sd::LongType* dimension, int dimensionLength, sd::LongType const* tadShapeInfo,
    sd::LongType const* tadOffsets, sd::LongType const* tadShapeInfoZ, sd::LongType const* tadOffsetsZ) {
  auto stream = lc->getCudaStream();

  dim3 launchDims(256, 512, 8192);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hScalarShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hScalarShapeInfo)) return;

  if (xType != yType) throw std::runtime_error("NativeOpExecutioner::execScalarBool requires X & Y to have same type");

  if (!DataTypeUtils::isB(zType))
    throw std::runtime_error("NativeOpExecutioner::execScalarBool requires Z operand to have BOOL type");

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::scalar::ScalarBoolTransform,
      ::executeCudaAlongDimension(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalars, extraParams,
                                  dimension, dimensionLength, tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ),
      SD_COMMON_TYPES, SD_BOOL_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execScalarBool B failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalarInt(sd::LaunchContext* lc, int opNum, void const* hX,
                                        sd::LongType const* hXShapeInfo, void const* dX,
                                        sd::LongType const* dXShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                        void* dZ, sd::LongType const* dZShapeInfo, void const* hScalar,
                                        sd::LongType const* hScalarShapeInfo, void const* dScalar,
                                        sd::LongType const* dScalarShapeInfo, void* extraParams,
                                        bool allowParallelism) {
  auto stream = lc->getCudaStream();

  dim3 launchDims = dim3(256, 512, 8192);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hScalarShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hScalarShapeInfo)) return;

  if (xType != yType || zType != xType)
    throw std::runtime_error("NativeOpExecutioner::execScalarInt requires X & Y to have same type");

  if (!DataTypeUtils::isZ(zType))
    throw std::runtime_error("NativeOpExecutioner::execScalarInt requires Z operand to have INT type");

  BUILD_SINGLE_SELECTOR(
      xType, functions::scalar::ScalarIntTransform,
      ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalar, extraParams),
      SD_INTEGER_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execScalarInt failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalarInt(
    sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo, void const* dX,
    sd::LongType const* dXShapeInfo, void* extraParams, void* hZ, sd::LongType const* hZShapeInfo, void* dZ,
    sd::LongType const* dZShapeInfo, void const* hScalars, sd::LongType const* hScalarShapeInfo, void const* dScalars,
    sd::LongType const* dScalarShapeInfo, sd::LongType* dimension, int dimensionLength, sd::LongType const* tadShapeInfo,
    sd::LongType const* tadOffsets, sd::LongType const* tadShapeInfoZ, sd::LongType const* tadOffsetsZ) {
  auto stream = lc->getCudaStream();

  dim3 launchDims(256, 512, 8192);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hScalarShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hScalarShapeInfo)) return;

  if (xType != yType || zType != xType)
    throw std::runtime_error("NativeOpExecutioner::execScalarInt requires X & Y to have same type");

  if (!DataTypeUtils::isZ(zType))
    throw std::runtime_error("NativeOpExecutioner::execScalarInt requires Z operand to have INT type");

  BUILD_SINGLE_SELECTOR(
      xType, functions::scalar::ScalarIntTransform,
      ::executeCudaAlongDimension(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalars, extraParams,
                                  dimension, dimensionLength, tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ),
      SD_INTEGER_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execScalarInt B failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalar(sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo,
                                     void const* dX, sd::LongType const* dXShapeInfo, void* hZ,
                                     sd::LongType const* hZShapeInfo, void* dZ, sd::LongType const* dZShapeInfo,
                                     void const* hScalar, sd::LongType const* hScalarShapeInfo, void const* dScalar,
                                     sd::LongType const* dScalarShapeInfo, void* extraParams, bool allowParallelism) {
  auto stream = lc->getCudaStream();

  dim3 launchDims(256, 512, 8192);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hScalarShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hScalarShapeInfo)) return;

#ifdef SD_EXPERIMENTAL_ENABLED
  BUILD_PAIRWISE_SELECTOR(xType, yType, zType, functions::scalar::ScalarTransform,
                          ::executeCudaShaped(launchDims, stream, opType, dX, dXShapeInfo, hXShapeInfo, dZ, dZShapeInfo,
                                              hZShapeInfo, dScalar, extraParams),
                          SD_COMMON_TYPES, SD_COMMON_TYPES);
#else
  BUILD_SINGLE_SELECTOR_THRICE(xType, functions::scalar::ScalarTransform,
                               ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, dZ,
                                                   dZShapeInfo, hZShapeInfo, dScalar, extraParams),
                               SD_COMMON_TYPES);
#endif

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execScalar failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalar(sd::LaunchContext* lc, int opNum, void const* hX, sd::LongType const* hXShapeInfo,
                                     void const* dX, sd::LongType const* dXShapeInfo, void* extraParams, void* hZ,
                                     sd::LongType const* hZShapeInfo, void* dZ, sd::LongType const* dZShapeInfo,
                                     void const* hScalars, sd::LongType const* hScalarShapeInfo, void const* dScalars,
                                     sd::LongType const* dScalarShapeInfo, sd::LongType* dimension, int dimensionLength,
                                     sd::LongType const* tadShapeInfo, sd::LongType const* tadOffsets,
                                     sd::LongType const* tadShapeInfoZ, sd::LongType const* tadOffsetsZ) {
  auto stream = lc->getCudaStream();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hScalarShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (shape::isEmpty(hXShapeInfo) || shape::isEmpty(hScalarShapeInfo)) return;

  dim3 launchDims(256, 256, 16384);

#ifdef SD_EXPERIMENTAL_ENABLED
  BUILD_PAIRWISE_SELECTOR(
      xType, yType, zType, functions::scalar::ScalarTransform,
      ::executeCudaAlongDimension(launchDims, stream, opType, dX, dXShapeInfo, dZ, dZShapeInfo, dScalars, extraParams,
                                  dimension, dimensionLength, tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ),
      SD_COMMON_TYPES, SD_COMMON_TYPES);
#else
  BUILD_SINGLE_SELECTOR_THRICE(
      xType, functions::scalar::ScalarTransform,
      ::executeCudaAlongDimension(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalars, extraParams,
                                  dimension, dimensionLength, tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ),
      SD_COMMON_TYPES);
#endif

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execScalar B failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execRandom(sd::LaunchContext* lc, int opNum, sd::Pointer stateHost, void* hZ,
                                     sd::LongType const* hZShapeInfo, void* dZ, sd::LongType const* dZShapeInfo,
                                     void* extraArguments) {
  auto stream = lc->getCudaStream();
  auto sizeOf = sizeof(sd::graph::RandomGenerator);
  sd::Pointer stateDevice;

  cudaError_t res = cudaMalloc(reinterpret_cast<void**>(&stateDevice), sizeOf);
  checkCudaErrors(cudaStreamSynchronize(*stream));
  checkCudaErrors(cudaMemcpyAsync(stateDevice, stateHost, sizeOf, cudaMemcpyHostToDevice, *stream));

  dim3 launchDims = dim3(512, 512, 32768);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  auto rng = reinterpret_cast<sd::graph::RandomGenerator*>(stateHost);

  // functions::random::RandomFunction<float>::executeCudaSingle(launchDims, extraPointers, opType, stateHost, dZ,
  // dZShapeInfo, extraArguments),
  BUILD_SINGLE_SELECTOR(zType, functions::random::RandomFunction,
                        ::executeCudaSingle(launchDims, stream, opNum, stateDevice, dZ, dZShapeInfo, extraArguments),
                        SD_FLOAT_TYPES);

  res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execRandom X failed", res);

  cudaFree(stateDevice);

  rng->rewindH(shape::length(hZShapeInfo));
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execRandom(sd::LaunchContext* lc, int opNum, sd::Pointer stateHost, void const* hX,
                                     sd::LongType const* hXShapeInfo, void const* dX, sd::LongType const* dXShapeInfo,
                                     void* hZ, sd::LongType const* hZShapeInfo, void* dZ,
                                     sd::LongType const* dZShapeInfo, void* extraArguments) {
  auto stream = lc->getCudaStream();

  auto sizeOf = sizeof(sd::graph::RandomGenerator);
  sd::Pointer stateDevice;

  cudaError_t res = cudaMalloc(reinterpret_cast<void**>(&stateDevice), sizeOf);
  checkCudaErrors(cudaStreamSynchronize(*stream));
  checkCudaErrors(cudaMemcpyAsync(stateDevice, stateHost, sizeOf, cudaMemcpyHostToDevice, *stream));

  auto rng = reinterpret_cast<sd::graph::RandomGenerator*>(stateHost);

  dim3 launchDims = dim3(512, 512, 32768);
  auto xType = sd::ArrayOptions::dataType(hZShapeInfo);

  BUILD_SINGLE_SELECTOR(
      xType, functions::random::RandomFunction,
      ::executeCudaDouble(launchDims, stream, opNum, stateDevice, dX, dXShapeInfo, dZ, dZShapeInfo, extraArguments),
      SD_FLOAT_TYPES);

  res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execRandom XY failed", res);

  cudaFree(stateDevice);

  rng->rewindH(shape::length(hZShapeInfo));
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execRandom(sd::LaunchContext* lc, int opNum, sd::Pointer stateHost, void const* hX,
                                     sd::LongType const* hXShapeInfo, void const* dX, sd::LongType const* dXShapeInfo,
                                     void const* hY, sd::LongType const* hYShapeInfo, void const* dY,
                                     sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                     void* dZ, sd::LongType const* dZShapeInfo, void* extraArguments) {
  auto stream = lc->getCudaStream();
  auto sizeOf = sizeof(sd::graph::RandomGenerator);
  sd::Pointer stateDevice;

  cudaError_t res = cudaMalloc(reinterpret_cast<void**>(&stateDevice), sizeOf);
  checkCudaErrors(cudaStreamSynchronize(*stream));
  checkCudaErrors(cudaMemcpyAsync(stateDevice, stateHost, sizeOf, cudaMemcpyHostToDevice, *stream));

  auto rng = reinterpret_cast<sd::graph::RandomGenerator*>(stateHost);

  dim3 launchDims = dim3(512, 512, 32768);
  auto xType = sd::ArrayOptions::dataType(hZShapeInfo);

  BUILD_SINGLE_SELECTOR(xType, functions::random::RandomFunction,
                        ::executeCudaTriple(launchDims, stream, opNum, stateDevice, dX, dXShapeInfo, dY, dYShapeInfo,
                                            dZ, dZShapeInfo, extraArguments),
                        SD_FLOAT_TYPES);

  res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execRandom XYZ failed", res);

  cudaFree(stateDevice);

  rng->rewindH(shape::length(hZShapeInfo));
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3All(sd::LaunchContext* lc, int opNum, void const* hX,
                                         sd::LongType const* hXShapeInfo, void const* dX,
                                         sd::LongType const* dXShapeInfo, void* extraParamsVals, void const* hY,
                                         sd::LongType const* hYShapeInfo, void const* dY,
                                         sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                         void* dZ, sd::LongType const* dZShapeInfo, sd::LongType* dimension, int dimensionLength,
                                         sd::LongType const* xTadShapeInfo, sd::LongType const* xOffsets,
                                         sd::LongType const* yTadShapeInfo, sd::LongType const* yOffsets) {
  auto stream = lc->getCudaStream();
  auto allocationPointer = lc->getAllocationPointer();
  auto reductionPointer = lc->getReductionPointer();

  if (sd::Environment::getInstance().isDebugAndVerbose()) printf("D119 opType:[%i]\n", opNum);

  dim3 launchDims(shape::length(hZShapeInfo), SD_CUDA_BLOCK_SIZE / 2, 1024);

  if (sd::Environment::getInstance().isVerbose() && launchDims.x == 1) printf("AD119 opType:[%i]\n", opNum);

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (yType != xType)
    throw sd::datatype_exception::build("NativeOpExecutioner::execReduce3All both operands must have same data type",
                                        xType, yType);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::reduce3::Reduce3,
      ::execAll(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, extraParamsVals, dZ, dZShapeInfo,
                dimension, dimensionLength, 1, allocationPointer, xTadShapeInfo, xOffsets, yTadShapeInfo, yOffsets),
      SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduce3All failed", res);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3TAD(sd::LaunchContext* lc, int opNum, void const* hX,
                                         sd::LongType const* hXShapeInfo, void const* dX,
                                         sd::LongType const* dXShapeInfo, void* extraParams, void const* hY,
                                         sd::LongType const* hYShapeInfo, void const* dY,
                                         sd::LongType const* dYShapeInfo, void* hZ, sd::LongType const* hZShapeInfo,
                                         void* dZ, sd::LongType const* dZShapeInfo, sd::LongType* dimension, int dimensionLength,
                                         sd::LongType const* tadShapeInfo, sd::LongType const* tadOffsets,
                                         sd::LongType const* yTadShapeInfo, sd::LongType const* yTadOffsets) {
  if (shape::isScalar(hZShapeInfo)) {
    NativeOpExecutioner::execReduce3(lc, opNum, hX, hXShapeInfo, dX, dXShapeInfo, extraParams, hY, hYShapeInfo, dY,
                                     dYShapeInfo, hZ, hZShapeInfo, dZ, dZShapeInfo);
    return;
  }

  auto stream = lc->getCudaStream();
  auto allocationPointer = lc->getAllocationPointer();

  auto xType = sd::ArrayOptions::dataType(hXShapeInfo);
  auto yType = sd::ArrayOptions::dataType(hYShapeInfo);
  auto zType = sd::ArrayOptions::dataType(hZShapeInfo);

  if (xType != yType)
    throw sd::datatype_exception::build("NativeOpExecutioner::execReduce3TAD requires Y operand to have X type", xType,
                                        yType);

  if (!DataTypeUtils::isR(zType))
    throw sd::datatype_exception::build(
        "NativeOpExecutioner::execReduce3TAD requires Z operand to have floating point data type", zType);

  auto numBlocks = shape::length(hZShapeInfo);
  dim3 launchDims(numBlocks == 0 ? 1 : numBlocks, SD_CUDA_BLOCK_SIZE, 1024);

  BUILD_DOUBLE_SELECTOR(
      xType, zType, functions::reduce3::Reduce3,
      ::exec(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, extraParams, dZ, dZShapeInfo, dimension,
             dimensionLength, 1, allocationPointer, tadShapeInfo, tadOffsets, yTadShapeInfo, yTadOffsets),
      SD_COMMON_TYPES, SD_FLOAT_TYPES);

  // TODO: remove after the release
  auto res = cudaStreamSynchronize(*stream);
  if (res != 0) throw cuda_exception::build("execReduce3TAD failed", res);
}
