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
//  @author GS <sgazeos@gmail.com>
//
#include <array/NDArrayFactory.h>
#include <exceptions/cuda_exception.h>
#include <helpers/ConstantTadHelper.h>
#include <helpers/PointersManager.h>
#include <helpers/ShapeUtils.h>
#include <helpers/TAD.h>
#include <ops/declarable/helpers/segment.h>
#include <ops/declarable/helpers/segment_common.h>

namespace sd {
namespace ops {
namespace helpers {
// -------------------------------------------------------------------------------------------------------------- //
// Segment ops linear kernels
// -------------------------------------------------------------------------------------------------------------- //
template <typename T, typename I>
static SD_KERNEL void segmentSumLinearKernel(const void* input, const sd::LongType* inputShape, int* starts,
                                             int* lengths, sd::LongType numOfClasses, void* output,
                                             const sd::LongType* outputShape) {
  __shared__ T* val;
  __shared__ sd::LongType xLen, zLen, segment, zIndex;
  __shared__ const T* x;
  __shared__ T* z;
  __shared__ int threadsPerSegment, start, finish;

  if (threadIdx.x == 0) {
    threadsPerSegment = (gridDim.x + numOfClasses - 1) / numOfClasses;
    segment = blockIdx.x / threadsPerSegment;
    x = reinterpret_cast<const T*>(input);
    z = reinterpret_cast<T*>(output);

    xLen = shape::length(inputShape);
    zLen = shape::length(outputShape);

    if (segment < numOfClasses) {
      zIndex = shape::getIndexOffset(segment, outputShape);
      start = starts[segment];
      finish = start + lengths[segment];
      // val[segment] = ;
      z[zIndex] = x[shape::getIndexOffset(start, inputShape)];
    }
  }
  __syncthreads();

  for (auto e = start + threadIdx.x + 1; e < finish; e += blockDim.x) {
    auto xIndex = shape::getIndexOffset(e, inputShape);
    sd::math::atomics::sd_atomicAdd(&z[zIndex], x[xIndex]);
  }
}
// -------------------------------------------------------------------------------------------------------------- //

template <typename T, typename I>
static SD_KERNEL void unsortedSegmentSumLinearKernel(const void* input, const sd::LongType* inputShape,
                                                     const void* indices, const sd::LongType* indicesShape, int* starts,
                                                     int* lengths, sd::LongType numOfClasses, void* output,
                                                     const sd::LongType* outputShape) {
  __shared__ T* val;
  __shared__ sd::LongType xLen, zLen, segment, zIndex;
  __shared__ const T* x;
  __shared__ T* z;
  __shared__ const I* y;  // int threadsPerSegment, start, finish;

  if (threadIdx.x == 0) {
    segment = blockIdx.x;
    x = reinterpret_cast<const T*>(input);
    z = reinterpret_cast<T*>(output);
    y = reinterpret_cast<const I*>(indices);
    xLen = shape::length(inputShape);
    zLen = shape::length(outputShape);

    zIndex = shape::getIndexOffset(segment, outputShape);
    if (lengths[segment] > 0)
      z[zIndex] = x[shape::getIndexOffset(starts[segment], inputShape)];
    else
      z[zIndex] = 0;  // DataTypeUtils::max<T>();
  }
  __syncthreads();

  if (lengths[segment] > 0)
    for (auto e = threadIdx.x; e < xLen; e += blockDim.x) {
      auto xIndex = shape::getIndexOffset(e, inputShape);
      auto yIndex = shape::getIndexOffset(e, indicesShape);
      if (y[yIndex] == segment && e != starts[segment]) {
        sd::math::atomics::sd_atomicAdd(&z[zIndex], x[xIndex]);
      }
    }
}
// -------------------------------------------------------------------------------------------------------------- //
// SegmentSum kernel
template <typename T, typename I>
static SD_KERNEL void segmentSumTadKernel(const void* inputBuf, const sd::LongType* inputShape,
                                          const sd::LongType* inputTads, const sd::LongType* inputTadOffsets,
                                          const I* indices, int* starts, int* lengths, sd::LongType numOfClasses,
                                          void* outputBuf, const sd::LongType* outputShape,
                                          const sd::LongType* outputTads, const sd::LongType* outputTadOffsets) {
  __shared__ T* val;
  __shared__ sd::LongType len, zIndex, total;
  __shared__ T* z;
  __shared__ int start, finish;

  if (threadIdx.x == 0) {
    auto segment = indices[blockIdx.x];  // / threadsPerSegment;
    z = reinterpret_cast<T*>(outputBuf) + outputTadOffsets[segment];
    len = shape::length(inputTads);
    start = starts[segment];
    finish = start + lengths[segment];
    total = shape::sizeAt(inputShape, 0);
  }
  __syncthreads();

  auto idx = blockIdx.x;
  if (blockIdx.x <= total) {
    auto x = reinterpret_cast<const T*>(inputBuf) + inputTadOffsets[idx];
    if (blockIdx.x == start) {
      for (auto e = threadIdx.x; e < len; e += blockDim.x) {
        auto xIndex = shape::getIndexOffset(e, inputTads);
        auto zIndex = shape::getIndexOffset(e, outputTads);
        sd::math::atomics::sd_atomicAdd(&z[zIndex], x[xIndex]);
      }
    } else {
      for (auto e = threadIdx.x; e < len; e += blockDim.x) {
        auto xIndex = shape::getIndexOffset(e, inputTads);
        auto zIndex = shape::getIndexOffset(e, outputTads);
        if (lengths[indices[idx]]) sd::math::atomics::sd_atomicAdd(&z[zIndex], x[xIndex]);
      }
    }
  }
}
// -------------------------------------------------------------------------------------------------------------- //

template <typename T, typename I>
static void segmentSumFunctor_(sd::LaunchContext* context, NDArray* input, NDArray* indices, NDArray* output) {
  auto stream = context->getCudaStream();
  sd::LongType numClasses = indices->e<sd::LongType>(indices->lengthOf() - 1) + 1;
  NDArray classesRangesLens = NDArrayFactory::create<int>('c', {numClasses}, context);
  NDArray classesRangesBegs = NDArrayFactory::create<int>('c', {numClasses}, context);

  classesRangesBegs.assign(indices->lengthOf());
  classesRangesLens.assign(0);

  dim3 dims(numClasses, indices->lengthOf(), numClasses * 32 + 32);
  fillUpSegments(indices, numClasses, classesRangesBegs, classesRangesLens);
  int* begins = reinterpret_cast<int*>(classesRangesBegs.specialBuffer());
  int* lengths = reinterpret_cast<int*>(classesRangesLens.specialBuffer());

  if (input->isVector()) {
    segmentSumLinearKernel<T, I><<<numClasses, input->lengthOf(), numClasses * 32 + 32, *stream>>>(
        input->specialBuffer(), input->specialShapeInfo(), begins, lengths, numClasses, output->specialBuffer(),
        output->specialShapeInfo());
  } else {
    std::vector<sd::LongType> dimensions = ShapeUtils::evalDimsToExclude(input->rankOf(), {0});
    auto packX = sd::ConstantTadHelper::getInstance().tadForDimensions(input->shapeInfo(), dimensions);
    auto packZ = sd::ConstantTadHelper::getInstance().tadForDimensions(output->shapeInfo(), dimensions);
    auto inputTads = packX.specialShapeInfo();
    auto inputTadOffsets = packX.specialOffsets();
    auto outputTads = packZ.specialShapeInfo();
    auto outputTadOffsets = packZ.specialOffsets();
    segmentSumTadKernel<T, I><<<input->sizeAt(0), 512, 2048, *stream>>>(
        input->specialBuffer(), input->specialShapeInfo(), inputTads, inputTadOffsets,
        reinterpret_cast<I*>(indices->specialBuffer()), begins, lengths, numClasses, output->specialBuffer(),
        output->specialShapeInfo(), outputTads, outputTadOffsets);
  }
}
// -------------------------------------------------------------------------------------------------------------- //
void segmentSumFunctor(sd::LaunchContext* context, NDArray* input, NDArray* indices, NDArray* output) {
  NDArray::prepareSpecialUse({output}, {input, indices});
  output->nullify();
  BUILD_DOUBLE_SELECTOR(input->dataType(), indices->dataType(), segmentSumFunctor_, (context, input, indices, output),
                        SD_NUMERIC_TYPES, SD_INDEXING_TYPES);
  NDArray::registerSpecialUse({output}, {input, indices});
}

// -------------------------------------------------------------------------------------------------------------- //
template <typename T, typename I>
static void unsortedSegmentSumFunctor_(sd::LaunchContext* context, NDArray* input, NDArray* indices,
                                       sd::LongType numOfClasses, NDArray* output) {
  auto stream = context->getCudaStream();
  //        NDArray classes = NDArrayFactory::create<int>('c', {numOfClasses, 2});
  NDArray classesRangesBegs = NDArrayFactory::create<int>('c', {numOfClasses}, context);
  NDArray classesRangesLens = NDArrayFactory::create<int>('c', {numOfClasses}, context);
  //        NDArray row = NDArrayFactory::create<int>('c', {1, 2}, {(int)indices->lengthOf(), (int)0});
  //        classes.applyTrueBroadcast(sd::BroadcastOpsTuple::Assign(), &row, &classes);
  classesRangesBegs.assign(indices->lengthOf());
  classesRangesLens.assign(0);
  dim3 dims(numOfClasses, indices->lengthOf(), (numOfClasses + 1) * 64);
  //        int* classesBuf = reinterpret_cast<int*>(classes.specialBuffer());
  fillUpSegments(indices, numOfClasses, classesRangesBegs, classesRangesLens);
  int* begins = reinterpret_cast<int*>(classesRangesBegs.specialBuffer());
  int* lengths = reinterpret_cast<int*>(classesRangesLens.specialBuffer());

  if (input->isVector()) {
    unsortedSegmentSumLinearKernel<T, I><<<dims.x, dims.y, dims.z, *stream>>>(
        input->specialBuffer(), input->specialShapeInfo(), indices->specialBuffer(), indices->specialShapeInfo(),
        begins, lengths, numOfClasses, output->specialBuffer(), output->specialShapeInfo());
  } else {
    output->assign(0);
    std::vector<sd::LongType> dimensions = ShapeUtils::evalDimsToExclude(input->rankOf(), {0});
    auto packX = sd::ConstantTadHelper::getInstance().tadForDimensions(input->shapeInfo(), dimensions);
    auto packZ = sd::ConstantTadHelper::getInstance().tadForDimensions(output->shapeInfo(), dimensions);
    auto inputTads = packX.specialShapeInfo();
    auto inputTadOffsets = packX.specialOffsets();
    auto outputTads = packZ.specialShapeInfo();
    auto outputTadOffsets = packZ.specialOffsets();
    dims.x = input->sizeAt(0);
    segmentSumTadKernel<T, I><<<dims.x, dims.y, dims.z, *stream>>>(
        input->specialBuffer(), input->specialShapeInfo(), inputTads, inputTadOffsets,
        reinterpret_cast<I*>(indices->specialBuffer()), begins, lengths, numOfClasses, output->specialBuffer(),
        output->specialShapeInfo(), outputTads, outputTadOffsets);
  }
}
// -------------------------------------------------------------------------------------------------------------- //
void unsortedSegmentSumFunctor(sd::LaunchContext* context, NDArray* input, NDArray* indices, sd::LongType numOfClasses,
                               NDArray* output) {
  NDArray::prepareSpecialUse({output}, {input, indices});
  output->nullify();
  BUILD_DOUBLE_SELECTOR(input->dataType(), indices->dataType(), unsortedSegmentSumFunctor_,
                        (context, input, indices, numOfClasses, output), SD_NUMERIC_TYPES, SD_INDEXING_TYPES);
  NDArray::registerSpecialUse({output}, {input, indices});
}

// -------------------------------------------------------------------------------------------------------------- //
// Backpropagate ops
// -------------------------------------------------------------------------------------------------------------- //
// Sorted sum backpropagate
template <typename T, typename I>
static SD_KERNEL void segmentSumBPLinearKernel(const void* inputBuf, const sd::LongType* inputShape, const void* eps,
                                               const sd::LongType* epsShape, const void* indicesBuf,
                                               const sd::LongType* indicesShape, void* outputBuf,
                                               const sd::LongType* outputShape) {
  auto x = reinterpret_cast<const T*>(inputBuf);
  auto y = reinterpret_cast<const I*>(indicesBuf);
  auto z = reinterpret_cast<T*>(outputBuf);
  auto gradOut = reinterpret_cast<const T*>(eps);
  __shared__ sd::LongType xLen, gradLen;

  if (threadIdx.x == 0) {
    xLen = shape::length(inputShape);
    gradLen = shape::length(epsShape);
  }
  __syncthreads();

  auto start = blockIdx.x * blockDim.x + threadIdx.x;
  auto step = gridDim.x * blockDim.x;

  for (auto e = start; e < xLen; e += step) {
    auto zOffset = shape::getIndexOffset(e, outputShape);
    auto xOffset = shape::getIndexOffset(e, inputShape);
    auto yOffset = shape::getIndexOffset(e, indicesShape);
    auto classIndex = y[yOffset];
    auto gradOffsetO = shape::getIndexOffset(classIndex, epsShape);

    z[zOffset] = gradOut[gradOffsetO];
  }
}
// -------------------------------------------------------------------------------------------------------------- //
template <typename T, typename I>
static SD_KERNEL void segmentSumBPTadKernel(const void* inputBuf, const sd::LongType* inputShape, const void* eps,
                                            const sd::LongType* epsShape, const void* indicesBuf,
                                            const sd::LongType* indicesShape, void* outputBuf,
                                            const sd::LongType* outputShape, const sd::LongType* inputTad,
                                            const sd::LongType* inputOffsets, const sd::LongType* gradOutTad,
                                            const sd::LongType* gradOutOffsets, const sd::LongType* outTad,
                                            const sd::LongType* outOffsets) {
  __shared__ const T* x;
  __shared__ const T* gradOut;
  __shared__ const I* y;
  __shared__ T* z;
  __shared__ sd::LongType xLen, yLen, gradLen, currentLen;

  if (threadIdx.x == 0) {
    xLen = shape::length(inputShape);
    x = reinterpret_cast<const T*>(inputBuf);
    y = reinterpret_cast<const I*>(indicesBuf);
    z = reinterpret_cast<T*>(outputBuf);
    yLen = shape::length(indicesShape);
    gradOut = reinterpret_cast<const T*>(eps);
    gradLen = shape::length(epsShape);
    currentLen = shape::length(outTad);
  }
  __syncthreads();

  for (auto i = blockIdx.x; i < yLen; i += gridDim.x) {
    auto yIndex = shape::getIndexOffset(i, indicesShape);
    auto segment = y[yIndex];
    auto currentOut = z + outOffsets[i];
    auto outGrad = gradOut + gradOutOffsets[segment];

    for (auto e = threadIdx.x; e < currentLen; e += blockDim.x) {
      currentOut[e] = outGrad[e];
    }
  }
}
// -------------------------------------------------------------------------------------------------------------- //
template <typename T, typename I>
sd::Status segmentSumFunctorBP_(sd::LaunchContext* context, NDArray* input, NDArray* indices, NDArray* gradOut,
                                NDArray* output) {
  auto stream = context->getCudaStream();
  NDArray::prepareSpecialUse({output}, {input, indices, gradOut});
  if (input->isVector()) {
    sd::LongType loop_size = input->lengthOf();
    auto numOfClasses = gradOut->lengthOf();  // indices->e<sd::LongType>(loop_size - 1);
    segmentSumBPLinearKernel<T, I><<<gradOut->lengthOf(), input->lengthOf(), 256, *stream>>>(
        input->specialBuffer(), input->specialShapeInfo(), gradOut->specialBuffer(), gradOut->specialShapeInfo(),
        indices->specialBuffer(), indices->specialShapeInfo(), output->specialBuffer(), output->specialShapeInfo());
  } else {
    std::vector<sd::LongType> dimensions = ShapeUtils::evalDimsToExclude(input->rankOf(), {0});
    auto packX = sd::ConstantTadHelper::getInstance().tadForDimensions(input->shapeInfo(), dimensions);
    auto packZ = sd::ConstantTadHelper::getInstance().tadForDimensions(output->shapeInfo(), dimensions);
    auto packGradOut = sd::ConstantTadHelper::getInstance().tadForDimensions(gradOut->shapeInfo(), dimensions);
    auto inputTads = packX.specialShapeInfo();
    auto inputTadOffsets = packX.specialOffsets();
    auto outputTads = packZ.specialShapeInfo();
    auto outputTadOffsets = packZ.specialOffsets();
    auto gradOutTads = packGradOut.specialShapeInfo();
    auto gradOutTadOffsets = packGradOut.specialOffsets();

    segmentSumBPTadKernel<T, I><<<gradOut->lengthOf(), input->lengthOf(), 256, *stream>>>(
        input->specialBuffer(), input->specialShapeInfo(), gradOut->specialBuffer(), gradOut->specialShapeInfo(),
        indices->specialBuffer(), indices->specialShapeInfo(), output->specialBuffer(), output->specialShapeInfo(),
        inputTads, inputTadOffsets, gradOutTads, gradOutTadOffsets, outputTads, outputTadOffsets);
  }
  NDArray::registerSpecialUse({output}, {input, indices, gradOut});
  return sd::Status::OK;
}
// -------------------------------------------------------------------------------------------------------------- //

sd::Status segmentSumFunctorBP(sd::LaunchContext* context, NDArray* input, NDArray* indices, NDArray* gradOut,
                               NDArray* output) {
  NDArray::prepareSpecialUse({output}, {input, indices, gradOut});
  BUILD_DOUBLE_SELECTOR(output->dataType(), indices->dataType(), return segmentSumFunctorBP_,
                        (context, input, indices, gradOut, output), SD_FLOAT_TYPES, SD_INDEXING_TYPES);
  NDArray::registerSpecialUse({output}, {input, indices, gradOut});
}

template <typename T, typename I>
static sd::Status unsortedSegmentSumFunctorBP_(sd::LaunchContext* context, NDArray* input, NDArray* indices,
                                               NDArray* gradOut, sd::LongType numOfClasses, NDArray* output) {
  auto stream = context->getCudaStream();
  NDArray::prepareSpecialUse({output}, {input, indices, gradOut});
  if (input->isVector()) {
    sd::LongType loop_size = input->lengthOf();
    auto numOfClasses = gradOut->lengthOf();  // indices->e<sd::LongType>(loop_size - 1);
    segmentSumBPLinearKernel<T, I><<<gradOut->lengthOf(), input->lengthOf(), 256, *stream>>>(
        input->specialBuffer(), input->specialShapeInfo(), gradOut->specialBuffer(), gradOut->specialShapeInfo(),
        indices->specialBuffer(), indices->specialShapeInfo(), output->specialBuffer(), output->specialShapeInfo());
  } else {
    std::vector<sd::LongType> dimensions = ShapeUtils::evalDimsToExclude(input->rankOf(), {0});
    auto packX = sd::ConstantTadHelper::getInstance().tadForDimensions(input->shapeInfo(), dimensions);
    auto packZ = sd::ConstantTadHelper::getInstance().tadForDimensions(output->shapeInfo(), dimensions);
    auto packGradOut = sd::ConstantTadHelper::getInstance().tadForDimensions(gradOut->shapeInfo(), dimensions);
    auto inputTads = packX.specialShapeInfo();
    auto inputTadOffsets = packX.specialOffsets();
    auto outputTads = packZ.specialShapeInfo();
    auto outputTadOffsets = packZ.specialOffsets();
    auto gradOutTads = packGradOut.specialShapeInfo();
    auto gradOutTadOffsets = packGradOut.specialOffsets();

    segmentSumBPTadKernel<T, I><<<gradOut->lengthOf(), input->lengthOf(), 256, *stream>>>(
        input->specialBuffer(), input->specialShapeInfo(), gradOut->specialBuffer(), gradOut->specialShapeInfo(),
        indices->specialBuffer(), indices->specialShapeInfo(), output->specialBuffer(), output->specialShapeInfo(),
        inputTads, inputTadOffsets, gradOutTads, gradOutTadOffsets, outputTads, outputTadOffsets);
  }
  NDArray::registerSpecialUse({output}, {input, indices, gradOut});
  return sd::Status::OK;
}
// -------------------------------------------------------------------------------------------------------------- //
sd::Status unsortedSegmentSumFunctorBP(sd::LaunchContext* context, NDArray* input, NDArray* indices, NDArray* gradOut,
                                       sd::LongType numOfClasses, NDArray* output) {
  NDArray::prepareSpecialUse({output}, {input, indices, gradOut});
  BUILD_DOUBLE_SELECTOR(output->dataType(), indices->dataType(), return unsortedSegmentSumFunctorBP_,
                        (context, input, indices, gradOut, numOfClasses, output), SD_FLOAT_TYPES, SD_INDEXING_TYPES);
  NDArray::registerSpecialUse({output}, {input, indices, gradOut});
}

}  // namespace helpers
}  // namespace ops
}  // namespace sd
