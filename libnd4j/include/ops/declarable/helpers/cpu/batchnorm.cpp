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
// @author Yurii Shyrma (iuriish@yahoo.com)
//

#include <execution/Threads.h>
#include <helpers/OmpLaunchHelper.h>
#include <helpers/ShapeUtils.h>
#include <ops/declarable/helpers/batchnorm.h>

#if NOT_EXCLUDED(OP_batchnorm)
namespace sd {
namespace ops {
namespace helpers {

//////////////////////////////////////////////////////////////////////////
template <typename T>
static void batchnorm_(const NDArray* input, const NDArray* mean, const NDArray* variance, const NDArray* gamma,
                       const NDArray* beta, NDArray* output, const std::vector<LongType>& axes, const double epsilon) {
  // formula: output = gamma * ((input - mean) / sqrt(variance + epsilon)) + beta

  const T* x = input->bufferAsT<T>();
  T* z = output->bufferAsT<T>();
  const T* m = mean->bufferAsT<T>();
  const T* v = variance->bufferAsT<T>();
  const T* g = gamma == nullptr ? nullptr : gamma->bufferAsT<T>();
  const T* b = beta == nullptr ? nullptr : beta->bufferAsT<T>();

  const bool xzSameOffset = shape::haveSameShapeAndStrides(input->shapeInfo(), output->shapeInfo());

  bool paramSameOffset = shape::haveSameShapeAndStrides(mean->shapeInfo(), variance->shapeInfo());
  if (paramSameOffset && gamma != nullptr)
    paramSameOffset &= shape::haveSameShapeAndStrides(mean->shapeInfo(), gamma->shapeInfo());
  if (paramSameOffset && beta != nullptr)
    paramSameOffset &= shape::haveSameShapeAndStrides(mean->shapeInfo(), beta->shapeInfo());

  const sd::LongType lenBig = input->lengthOf();
  const sd::LongType lenSmall = mean->lengthOf();

  const sd::LongType steps = lenBig / lenSmall;
  std::vector<sd::LongType> dimsToExclude = ShapeUtils::evalDimsToExclude(input->rankOf(), axes);

  OmpLaunchHelper info(lenBig, lenSmall);

  auto func = PRAGMA_THREADS_DO {
    sd::LongType* xOffsets = new sd::LongType[steps];
    sd::LongType* zOffsets = xzSameOffset ? xOffsets : new sd::LongType[steps];
    sd::LongType * auxBuff = new sd::LongType [2 * input->rankOf()];

    for (sd::LongType j = 0; j < lenSmall; ++j) {
      const bool isOwner = (j < info._numThreads) ? thread_id == j : thread_id == (j % info._numThreads);

      if (!isOwner) continue;

      const auto meanOffset = shape::getIndexOffset(j, mean->shapeInfo());
      const auto varOffset = paramSameOffset ? meanOffset : shape::getIndexOffset(j, variance->shapeInfo());

      const auto meanVal = m[meanOffset];
      auto sigmaInvGam = static_cast<T>(1) / sd::math::sd_sqrt<T, T>(v[varOffset] + epsilon);

      if (g != nullptr) {
        const auto gammaOffset = paramSameOffset ? meanOffset : shape::getIndexOffset(j, gamma->shapeInfo());
        sigmaInvGam *= g[gammaOffset];
      }

      T betaVal = static_cast<T>(0);
      if (b != nullptr) {
        const auto betaOffset = paramSameOffset ? meanOffset : shape::getIndexOffset(j, beta->shapeInfo());
        betaVal = b[betaOffset];
      }

      // calculate offsets for input and output
      shape::outerArrayOffsets(xOffsets, j, input->shapeInfo(), mean->shapeInfo(), auxBuff, dimsToExclude.data());
      if (!xzSameOffset)
        shape::outerArrayOffsets(zOffsets, j, output->shapeInfo(), mean->shapeInfo(), auxBuff, dimsToExclude.data());

      PRAGMA_OMP_SIMD
      for (sd::LongType i = 0; i < steps; ++i) z[zOffsets[i]] = (x[xOffsets[i]] - meanVal) * sigmaInvGam + betaVal;
    }

    delete[] auxBuff;
    delete[] xOffsets;
    if (!xzSameOffset) delete[] zOffsets;
  };

  samediff::Threads::parallel_do(func, info._numThreads);
}

//////////////////////////////////////////////////////////////////////////
template <typename T>
static void batchnorm2_(const NDArray* input, const NDArray* mean, const NDArray* variance, const NDArray* gamma,
                        const NDArray* beta, NDArray* output, const std::vector<int>& axes, const double epsilon) {
  // formula: output = gamma * ((input - mean) / sqrt(variance + epsilon)) + beta

  const auto x = input->bufferAsT<T>();
  auto z = output->bufferAsT<T>();
  const auto m = mean->bufferAsT<T>();
  const auto v = variance->bufferAsT<T>();
  const auto g = gamma == nullptr ? nullptr : gamma->bufferAsT<T>();
  const auto b = beta == nullptr ? nullptr : beta->bufferAsT<T>();

  // xRank == zRank, minRank = meanRank = varianceRank = gammaRank = betaRank
  const sd::Unsigned xRank = input->rankOf();
  const sd::Unsigned minRank = mean->rankOf();
  const sd::Unsigned numAxes = axes.size();

  const bool xzSameOffset = shape::haveSameShapeAndStrides(input->shapeInfo(), output->shapeInfo());

  bool paramSameOffset = shape::haveSameShapeAndStrides(mean->shapeInfo(), variance->shapeInfo());
  if (paramSameOffset && gamma != nullptr)
    paramSameOffset &= shape::haveSameShapeAndStrides(mean->shapeInfo(), gamma->shapeInfo());
  if (paramSameOffset && beta != nullptr)
    paramSameOffset &= shape::haveSameShapeAndStrides(mean->shapeInfo(), beta->shapeInfo());

  auto func = PRAGMA_THREADS_FOR {
    sd::LongType xzCoords[SD_MAX_RANK], minCoords[SD_MAX_RANK];

    for (sd::Unsigned i = 0, j = 0; i < xRank; ++i)
      if (j < numAxes && i != axes[j])
        minCoords[i] = 0;
      else
        ++j;

    for (auto i = start; i < stop; i++) {
      shape::index2coordsCPU(start, i, input->shapeInfo(), xzCoords);

      const auto xOffset = shape::getOffset(input->shapeInfo(), xzCoords);
      const auto zOffset = xzSameOffset ? xOffset : shape::getOffset(output->shapeInfo(), xzCoords);

      if (minRank == xRank) {
        for (sd::Unsigned j = 0; j < numAxes; ++j) minCoords[axes[j]] = xzCoords[axes[j]];
      } else  // minRank = numAxes = 1 in this case
        minCoords[0] = xzCoords[axes[0]];

      const auto meanOffset = shape::getOffset(mean->shapeInfo(), minCoords);
      const auto varianceOffset = paramSameOffset ? meanOffset : shape::getOffset(variance->shapeInfo(), minCoords);

      T sigmaInvGam = 1. / sd::math::sd_sqrt<T, T>(v[varianceOffset] + epsilon);

      if (g != nullptr) {
        const auto gammaOffset = paramSameOffset ? meanOffset : shape::getOffset(gamma->shapeInfo(), minCoords);
        sigmaInvGam *= g[gammaOffset];
      }

      z[zOffset] = (x[xOffset] - m[meanOffset]) * sigmaInvGam;

      if (b != nullptr) {
        const auto betaOffset = paramSameOffset ? meanOffset : shape::getOffset(beta->shapeInfo(), minCoords);
        z[zOffset] += b[betaOffset];
      }
    }
  };

  samediff::Threads::parallel_for(func, 0, input->lengthOf());
}

//////////////////////////////////////////////////////////////////////////
void batchnorm(const NDArray* input, const NDArray* mean, const NDArray* variance, const NDArray* gamma,
               const NDArray* beta, NDArray* output, const std::vector<LongType>& axes, const double epsilon) {
  // batchnorm2_ is still slower ?
  BUILD_SINGLE_SELECTOR(input->dataType(), batchnorm_, (input, mean, variance, gamma, beta, output, axes, epsilon),
                        SD_FLOAT_TYPES);
}

BUILD_SINGLE_TEMPLATE(template void batchnorm_,
                      (const NDArray* input, const NDArray* mean, const NDArray* variance, const NDArray* gamma,
                       const NDArray* beta, NDArray* output, const std::vector<sd::LongType>& axes, const double epsilon),
                      SD_FLOAT_TYPES);

}  // namespace helpers
}  // namespace ops
}  // namespace sd
#endif