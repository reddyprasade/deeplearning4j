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
// @author Yurii Shyrma (iuriish@yahoo.com), created on 20.04.2018
//

#include <helpers/Loops.h>
#include <helpers/LoopsCoordsHelper.h>
#include <ops/declarable/helpers/transforms.h>
#include <system/Environment.h>

#include <type_traits>
#if NOT_EXCLUDED(OP_pad)
namespace sd {
namespace ops {
namespace helpers {

template <typename T, size_t constRank>
static void copy_core_rank(const T* x, T* coreZ, const sd::LongType* xShapes, const sd::LongType* xStrides,
                           const sd::LongType* zStrides, int start, int stop) {
  static_assert(constRank > 1, "implement rank 1 directly");
  size_t loop_count = (stop - start);
  sd::ZipCoordsState<constRank - 1> cst;
  sd::zip_size_t offset = sd::init_coords<constRank - 1>(cst, start, xShapes, xStrides, zStrides);
  auto lastStrideX = xStrides[constRank - 1];
  auto lastStrideZ = zStrides[constRank - 1];
  auto inputLastSize = xShapes[constRank - 1];
  if (lastStrideZ == 1 && lastStrideX == 1) {
    for (auto k = 0; k < (stop - start); k++) {
      auto xPtr = &(x[offset.first]);
      auto zPtr = &(coreZ[offset.second]);
      for (int i = 0; i < inputLastSize; i++) {
        zPtr[i] = xPtr[i];
      }
      offset = sd::inc_coords<constRank - 1>(cst, offset);
    }
  } else {
    for (auto k = 0; k < loop_count; k++) {
      auto xPtr = &(x[offset.first]);
      auto zPtr = &(coreZ[offset.second]);
      for (int i = 0; i < inputLastSize; i++) {
        zPtr[i * lastStrideZ] = xPtr[i * lastStrideX];
      }
      offset = sd::inc_coords<constRank - 1>(cst, offset);
    }
  }
}

template <typename T>
void copy_core_generic(int rank, const T* x, T* coreZ, const sd::LongType* xShapes, const sd::LongType* xStrides,
                       const sd::LongType* zStrides, int start, int stop) {
  auto lastStrideX = xStrides[rank - 1];
  auto lastStrideZ = zStrides[rank - 1];
  auto inputLastSize = xShapes[rank - 1];
  sd::LongType coords[SD_MAX_RANK] = {};
  sd::LongType* ptrCoords = (sd::LongType*)&coords;

  zip_size_t offset = {};
  if (rank > 1) {
    index2coords_C(start, rank - 1, xShapes, ptrCoords);
    offset = offset_from_coords(xStrides, zStrides, ptrCoords, rank - 1);
  }
  if (lastStrideZ == 1 && lastStrideX == 1) {
    for (auto k = 0; k < (stop - start); k++) {
      auto xPtr = &(x[offset.first]);
      auto zPtr = &(coreZ[offset.second]);
      for (int i = 0; i < inputLastSize; i++) {
        zPtr[i] = xPtr[i];
      }
      offset = inc_coords(xShapes, xStrides, zStrides, ptrCoords, offset, rank - 1);
    }
  } else {
    for (auto k = 0; k < (stop - start); k++) {
      auto xPtr = &(x[offset.first]);
      auto zPtr = &(coreZ[offset.second]);
      for (int i = 0; i < inputLastSize; i++) {
        zPtr[i * lastStrideZ] = xPtr[i * lastStrideX];
      }
      offset = inc_coords(xShapes, xStrides, zStrides, ptrCoords, offset, rank - 1);
    }
  }
}
//////////////////////////////////////////////////////////////////////////
template <typename T>
void pad_(const int mode, const NDArray& input, const NDArray& paddings, NDArray& output, const NDArray& padValue) {
  const T* x = input.bufferAsT<T>();
  T* z = output.bufferAsT<T>();

  const sd::LongType* xShape = input.shapeOf();
  const sd::LongType* zShape = output.shapeOf();

  const int rank = input.rankOf();  // both input and output have the same rank
  const int rankMinusOne = rank - 1;
  const auto zLen = output.lengthOf();

  if (mode == 0) {  // CONSTANT case

    const T padVal = padValue.e<T>(0);

    auto xShapes = input.shapeOf();
    auto outShapes = output.shapeOf();
    auto xStrides = input.stridesOf();
    auto zStrides = output.stridesOf();
    sd::LongType paddingOffsetCoords[SD_MAX_RANK] = {};
    sd::LongType* ptrPaddingCoords = (sd::LongType*)&paddingOffsetCoords;
    bool all_paddings_zero = true;
    for (int j = 0; j < rank; j++) {
      auto p0 = paddings.e<sd::LongType>(j, 0);
      auto p1 = paddings.e<sd::LongType>(j, 1);
      paddingOffsetCoords[j] = p0;

      all_paddings_zero = all_paddings_zero && (p0 == 0) && (p1 == 0);
    }

    auto paddingOffset = all_paddings_zero ? 0 : sd::offset_from_coords(zStrides, ptrPaddingCoords, rank);

    auto inputLastSize = xShapes[rank - 1];

    // fill everything with padding Value
    if (!all_paddings_zero) output.assign(padVal, true);

    // fill the core from input
    auto coreZ = &(z[paddingOffset]);
    // iterate over core
    auto len = input.lengthOf() / inputLastSize;

    auto func = PRAGMA_THREADS_FOR {
      if (rank == 3) {
        copy_core_rank<T, 3>(x, coreZ, xShapes, xStrides, zStrides, start, stop);
      } else if (rank == 4) {
        copy_core_rank<T, 4>(x, coreZ, xShapes, xStrides, zStrides, start, stop);
      } else if (rank == 5) {
        copy_core_rank<T, 5>(x, coreZ, xShapes, xStrides, zStrides, start, stop);
      } else {
        copy_core_generic(rank, x, coreZ, xShapes, xStrides, zStrides, start, stop);
      }
    };
    // fixed restriction for smaller inputs
    auto numThreads = (zLen > 64 || inputLastSize > 4096) ? sd::Environment::getInstance().maxMasterThreads() : 1;
    samediff::Threads::parallel_tad(func, 0, len, 1, numThreads);

  } else {  // REFLECT and SYMMETRIC cases

    const sd::LongType shift1 = mode == 1 ? 0 : 1;  // REFLECT : SYMMETRIC
    const sd::LongType shift2 = mode == 1 ? 2 : 1;  // REFLECT : SYMMETRIC

    auto func = PRAGMA_THREADS_FOR {
      sd::LongType  zCoords[SD_MAX_RANK], xCoords[SD_MAX_RANK];

      for (auto i = start; i < stop; i++) {
        shape::index2coordsCPU(start, i, output.shapeInfo(), zCoords);
        const auto zOffset = shape::getOffset(output.shapeInfo(), zCoords);

        memcpy(xCoords, zCoords, rank * sizeof(int));

        for (int j = rankMinusOne; j >= 0; --j) {
          if (xShape[j] == zShape[j]) continue;

          xCoords[j] =
              zCoords[j] - paddings.e<sd::LongType>(j, 0);  // are ready to fill middle (within input dimension range)

          if (xCoords[j] < 0)
            xCoords[j] = -xCoords[j] - shift1;  // means fill from left
          else if (xCoords[j] >= xShape[j])
            xCoords[j] = 2 * xShape[j] - xCoords[j] - shift2;  // means fill from right
        }

        const auto xOffset = shape::getOffset(input.shapeInfo(), xCoords);
        z[zOffset] = x[xOffset];
      }
    };

    samediff::Threads::parallel_tad(func, 0, zLen);
  }
}

// //////////////////////////////////////////////////////////////////////////
// template<typename T>
// void pad2_(const int mode, const NDArray& input, const NDArray& paddings, NDArray& output, NDArray const& padValue) {

//     const int rank = output.rankOf();
//     std::vector<int> dimsToExclude(rank);
//     std::iota(dimsToExclude.begin(), dimsToExclude.end(), 0);             // fill with 0, 1, ... rank-1

//     sd::LongType numLeft    = paddings.e<sd::LongType>(rank-1,0);
//     sd::LongType numRight   = paddings.e<sd::LongType>(rank-1,1);
//     sd::LongType inDimSize  = input.sizeAt(rank-1);
//     sd::LongType outDimSize = output.sizeAt(rank-1);

//     std::vector<std::vector<sd::LongType>> outIdx = { std::vector<sd::LongType>(2*rank), {numLeft, numLeft +
//     inDimSize}, {0, numLeft}, {numLeft + inDimSize, outDimSize} };

//     for(int i = 0; i < rank-1; ++i) {
//         outIdx[0][2*i]     = paddings.e<sd::LongType>(i, 0);
//         outIdx[0][2*i + 1] = outIdx[0][2*i] + input.sizeAt(i);
//     }
//     outIdx[0][2*rank-1] = outIdx[0][2*rank-2] = 0;

//     // ***** populate innermost sub-arrays firstly ***** //
//     dimsToExclude.pop_back();

//     sd::LongType startL = mode == 1 ? 1 : 0;                            // REFLECT or SYMMETRIC
//     sd::LongType startR = mode == 1 ? inDimSize-2 : inDimSize-1;        // REFLECT or SYMMETRIC

//     sd::LongType numOfSubArrs = ShapeUtils::getNumOfSubArrs(input.shapeInfo(), dimsToExclude);

//     NDArray outSubArr0 = output(outIdx[0], true);

//     PRAGMA_OMP_PARALLEL_FOR
//     for(sd::LongType j = 0; j < numOfSubArrs; ++j) {

//         NDArray outSubArr1   = outSubArr0(j, dimsToExclude);
//         NDArray inSubArr     = input(j, dimsToExclude);
//         NDArray outSubArrMid = outSubArr1(outIdx[1]);

//         outSubArrMid.assign(inSubArr);      // assign middle

//         if(mode == 0)  { // CONSTANT
//             if(numLeft != 0) {
//                 NDArray temp = outSubArr1(outIdx[2]);
//                 temp.assign(padValue);                        // assign left
//             }
//             if(numRight != 0) {
//                 NDArray temp = outSubArr1(outIdx[3]);
//                 temp.assign(padValue);                        // assign right
//             }
//         }
//         else {                                                              // REFLECT or SYMMETRIC

//             for(sd::LongType k = numLeft-1, e = startL; k >= 0; --k, ++e)     // fill left side
//                 outSubArr1.t<T>(k) = inSubArr.t<T>(e);

//             for(sd::LongType k = numLeft + inDimSize, e = startR; k < outDimSize; ++k, --e)     // fill right side
//                 outSubArr1.t<T>(k) = inSubArr.t<T>(e);
//         }
//     }

//     // ***** fill rest of outer sub-arrays ***** //
//     std::vector<sd::LongType> outIdxInner(2, 0);
//     std::vector<sd::LongType> outIdxOuter(2, 0);

//     for(int i = rankBorder - 1; i >= 0; --i) {

//         dimsToExclude.pop_back();

//         outIdxInner.push_back(0), outIdxInner.push_back(0);
//         outIdxOuter.push_back(0), outIdxOuter.push_back(0);

//         sd::LongType numLeft  = paddings.e<sd::LongType>(i, 0);
//         sd::LongType numRight = paddings.e<sd::LongType>(i, 1);

//         if(numLeft == 0 && numRight == 0)
//             continue;

//         sd::LongType inDimSize  = input.sizeAt(i);
//         sd::LongType outDimSize = output.sizeAt(i);

//         if(mode == 0) {
//             outIdxOuter[0] = 0;                   outIdxOuter[1] = numLeft;
//             outIdxInner[0] = numLeft + inDimSize; outIdxInner[1] = outDimSize;
//         }

//         startL = mode == 1 ? numLeft + 1 : numLeft;                            // REFLECT or SYMMETRIC
//         startR = mode == 1 ? numLeft + inDimSize - 2 : numLeft + inDimSize-1;      // REFLECT or SYMMETRIC

//         numOfSubArrs = ShapeUtils::getNumOfSubArrs(output.shapeInfo(), dimsToExclude);

//         PRAGMA_OMP_PARALLEL_FOR_ARGS(firstprivate(outIdxOuter, outIdxInner))
//         for(sd::LongType j = 0; j < numOfSubArrs; ++j) {

//             NDArray outSubArr = output(j, dimsToExclude);

//             if(mode == 0)  { // CONSTANT

//                 if(numLeft != 0) {
//                     NDArray tempO = outSubArr(outIdxOuter);
//                     tempO.assign(padValue);                              // assign left
//                 }

//                 if(numRight != 0) {
//                     NDArray tempI = outSubArr(outIdxInner);
//                     tempI.assign(padValue);                              // assign right
//                 }
//             }
//             else {                                                              // REFLECT or SYMMETRIC

//                 for(sd::LongType k = numLeft-1, e = startL; k >= 0; --k, ++e) {    // fill left side
//                     outIdxOuter[0] = k;
//                     outIdxOuter[1] = k+1;
//                     outIdxInner[0] = e;
//                     outIdxInner[1] = e+1;
//                     NDArray outSubArrInner = outSubArr(outIdxInner);
//                     NDArray outSubArrOuter = outSubArr(outIdxOuter);
//                     outSubArrOuter.assign(outSubArrInner);
//                 }

//                 for(sd::LongType k = numLeft + inDimSize, e = startR; k < outDimSize; ++k, --e) {    // fill right
//                 side
//                     outIdxOuter[0] = k;
//                     outIdxOuter[1] = k+1;
//                     outIdxInner[0] = e;
//                     outIdxInner[1] = e+1;
//                     NDArray outSubArrInner = outSubArr(outIdxInner);
//                     NDArray outSubArrOuter = outSubArr(outIdxOuter);
//                     outSubArrOuter.assign(outSubArrInner);
//                 }
//             }
//         }
//     }
// }

void pad(sd::LaunchContext* context, const int mode, const NDArray& input, const NDArray& paddings, NDArray& output,
         NDArray const& padValue) {
  BUILD_SINGLE_SELECTOR(input.dataType(), pad_, (mode, input, paddings, output, padValue), SD_COMMON_TYPES);
}

//////////////////////////////////////////////////////////////////////////
template <typename T>
static void mirrorPad_(const NDArray& input, const NDArray& paddings, NDArray& output, const int mode) {
  // mode:  0 - REFLECT, else - SYMMETRIC
  const int reflBorder = (bool)mode ? 1 : 0;
  const int rank = input.rankOf();
  const sd::LongType outLen = output.lengthOf();

  if (rank <= 1) {
    const sd::LongType inLen = input.lengthOf();
    const auto leftSide = paddings.e<sd::LongType>(0);
    const auto leftSideCorrected = leftSide - reflBorder;
    const sd::LongType len = 2 * (inLen - 1) + leftSide + reflBorder;

    for (int i = 0; i < outLen; ++i) {
      if (i < leftSide)  // left side
        output.p(i, input.e<T>(leftSideCorrected - i));

      else if (i >= leftSide && i < leftSide + inLen)  // middle
        output.p(i, input.e<T>(i - leftSide));

      else  // right side
        output.p(i, input.e<T>(len - i));
    }
  } else {
    auto func = PRAGMA_THREADS_FOR {
      sd::LongType  inIdx[SD_MAX_RANK], outIdx[SD_MAX_RANK];

      for (auto i = start; i < stop; i++) {
        shape::index2coordsCPU(start, i, output.shapeInfo(), outIdx);

        for (int j = 0; j < rank; ++j) {
          const sd::LongType inLen = input.sizeAt(j);
          const auto leftSide = paddings.e<T>(j, 0);
          const auto leftSideCorrected = leftSide - reflBorder;
          const sd::LongType len = 2 * (inLen - 1) + leftSide + reflBorder;

          if (outIdx[j] < leftSide)  // left side
            inIdx[j] = leftSideCorrected - outIdx[j];

          else if (outIdx[j] >= leftSide && outIdx[j] < leftSide + inLen)  // middle
            inIdx[j] = outIdx[j] - leftSide;

          else  // right side
            inIdx[j] = len - outIdx[j];
        }

        auto outOffset = shape::getOffset(output.shapeInfo(), outIdx);
        auto inOffset = shape::getOffset(input.shapeInfo(), inIdx);
        reinterpret_cast<T*>(output.buffer())[outOffset] = reinterpret_cast<T const*>(input.buffer())[inOffset];
      }
    };

    samediff::Threads::parallel_for(func, 0, outLen);
  }
}

void mirrorPad(sd::LaunchContext* context, const NDArray& input, const NDArray& paddings, NDArray& output,
               const int mode) {
  BUILD_SINGLE_SELECTOR(input.dataType(), mirrorPad_, (input, paddings, output, mode), SD_COMMON_TYPES);
}

BUILD_SINGLE_TEMPLATE(template void mirrorPad_,
                      (const NDArray& input, const NDArray& paddings, NDArray& output, const int mode),
                      SD_COMMON_TYPES);

////////////////////////////////////////////////////////////////////////
/*// initial values of inIdx, outIdx, dim must be equal to zero
template<typename T>
static void recursiveLoopForPad_(const int mode, NDArray& input, const NDArray& paddings, NDArray& output,
std::vector<int> dimensions, int dim, int inIdx, int outIdx, NDArray& padValue ) {

    int leftOffset;
    // dimensions are array of input dimensions, it is sorted in increasing order
    // every time at the beginning we erase first element from it (not good idea to use vector for this purpose, but
luckily it is small enough)
    // then we use this array for tads building, every time while recursion the number of built tads becomes bigger
    dimensions.erase(dimensions.begin());
    // build tad basing on output array, also create auxiliary arrays pointing on required output array ranges
    shape::TAD tadOut(output.shapeInfo(), dimensions.data(), dimensions.size());
    tadOut.createTadOnlyShapeInfo();
    tadOut.createOffsets();
    auto subArrOut = NDArray(output.getBuffer(), tadOut.tadOnlyShapeInfo, output.getContext());
    auto subArr = NDArray(output.getBuffer(), tadOut.tadOnlyShapeInfo, output.getContext());
    // build tad basing on input array, also create auxiliary array pointing on required input array range
    shape::TAD tadIn(input.shapeInfo(), dimensions.data(), dimensions.size());
    tadIn.createTadOnlyShapeInfo();
    tadIn.createOffsets();
    auto subArrIn = NDArray(input.getBuffer(), tadIn.tadOnlyShapeInfo, output.getContext());
    // these indices take into account recursion and always point to actual tads numbers
    if (input.rankOf() > 1 && output.rankOf() > 1) {// only for non-vector cases
        outIdx = outIdx * output.sizeAt(dim + 1);
        inIdx = inIdx * input.sizeAt(dim + 1);
    }
    // current input tad number, we add to it unity in a loop
    int k = -1;
    // loop through current dimension
    for(int i = 0; i < output.sizeAt(dim); ++i) {
        // corresponds to outer range (relevant indices are absent in input)
        leftOffset = paddings.e<int>(dim, 0);
        if(i < leftOffset || i >= (input.sizeAt(dim) + leftOffset))
            continue;

        // increase input tads number
        ++k;
        // recursion condition allows for the fact that tad can't reduce to scalar
        if(dim < input.rankOf() - 2)
            recursiveLoopForPad(mode, input, paddings, output, dimensions, dim + 1, inIdx + k, outIdx + i, padValue);
        else if (paddings.sizeAt(0) > dim + 1){
            leftOffset = paddings.e<int>(dim + 1, 0);
            // shift buffers pointers to actual element position
            if (output.rankOf() > 1) {
                subArrOut.setBuffer(reinterpret_cast<T*>(output.getBuffer()) + tadOut.tadOffsets[outIdx + i]);
                subArrIn.setBuffer(reinterpret_cast<T*>(input.getBuffer()) + tadIn.tadOffsets[inIdx + i -
paddings.e<int>(dim, 0)]);
            }
            else {
                subArrOut.p(i, subArrIn.e<T>(i - leftOffset));
            }
            // most inner loop, corresponds to last dim = rank-1
            switch (mode) {
                case 0:             // CONSTANT mode
                    for(int j = 0; j < subArrOut.lengthOf(); ++j)
                            if(j < leftOffset || j >= (subArrIn.lengthOf() + leftOffset) )                  // firstly
fill with zeros outer ranges subArrOut.p(j, (T)0.f); else subArrOut.p(j, subArrIn.e<T>(j - leftOffset));   // fill
middle with elements of input array break;

                case 1:             // REFLECT mode
                    for(int j = 1;  j <= leftOffset; ++j)                                               // fill firstly
left side subArrOut.p(leftOffset - j, subArrIn.e<T>(j)); for(int j = 0; j < subArrIn.lengthOf(); ++j) // fill middle
                        subArrOut.p(leftOffset + j, subArrIn.e<T>(j));
                    for(int j = (subArrOut.lengthOf() - leftOffset); j < subArrOut.lengthOf(); ++j)     // fill right
side subArrOut.p(j, subArrIn.e<T>(subArrOut.lengthOf() - j - 1)); break;

                case 2:             // SYMMETRIC mode
                    for(int j = 1;  j <= leftOffset; ++j)                                               // fill firstly
left side subArrOut.p(leftOffset - j, subArrIn.e<T>(j-1)); for(int j = 0; j < subArrIn.lengthOf(); ++j) // fill middle
                        subArrOut.p(leftOffset + j, subArrIn.e<T>(j));
                    for(int j = (subArrOut.lengthOf() - leftOffset); j < subArrOut.lengthOf(); ++j)     // fill right
side subArrOut.p(j, subArrIn.e<T>(subArrOut.lengthOf() - j)); break;
            }
        }
        else {

             if (mode == 0 && input.rankOf() < 2)
                 subArrOut.p(i, subArrIn.e<T>(i - leftOffset));   // fill middle with elements of input array
        }
    }
    // populate sub-array formed previously
    leftOffset = paddings.e<int>(dim,0);
    switch (mode) {
        case 0:         // CONSTANT mode
            for(int j = 1;  j <= leftOffset; ++j) {
                // fill left side with padValue
                if (output.rankOf() > 1) {
                    subArrOut.setBuffer(
                            reinterpret_cast<T*>(output.getBuffer()) + tadOut.tadOffsets[outIdx + leftOffset - j]);
                    subArrOut.assign(padValue);
                }
                else {
                    subArrOut.p(j - 1, padValue);
                }
            }
//            output.printIndexedBuffer("Output at");
            for(int j = (output.sizeAt(dim) - leftOffset); j < output.sizeAt(dim); ++j) {       // fill left side with
zeros if (output.rankOf() > 1) { subArrOut.setBuffer(reinterpret_cast<T*>(output.getBuffer()) + tadOut.tadOffsets[outIdx
+ j]); subArrOut.assign(padValue);
                }
                else {
                    subArrOut.p(j, padValue);
                }
            }
            break;

        case 1:         // REFLECT mode
            for(int j = 1;  j <= leftOffset; ++j) {                                                     // fill left
side subArr.setBuffer(reinterpret_cast<T*>(output.getBuffer()) + tadOut.tadOffsets[outIdx + leftOffset + j]);
                subArrOut.setBuffer(reinterpret_cast<T*>(output.getBuffer()) + tadOut.tadOffsets[outIdx + leftOffset -
j]); subArrOut.assign(&subArr);
            }
            for(int j = (output.sizeAt(dim) - leftOffset); j < output.sizeAt(dim); ++j) {       // fill right side
                subArr.setBuffer(reinterpret_cast<T*>(output.getBuffer()) + tadOut.tadOffsets[outIdx +
output.sizeAt(dim) + leftOffset - 1 - j]); subArrOut.setBuffer(reinterpret_cast<T*>(output.getBuffer()) +
tadOut.tadOffsets[outIdx + j]); subArrOut.assign(&subArr);
            }
            break;

        case 2:         // SYMMETRIC mode
            for(int j = 1;  j <= leftOffset; ++j) {                                                     // fill left
side subArr.setBuffer(reinterpret_cast<T*>(output.getBuffer()) + tadOut.tadOffsets[outIdx + leftOffset + j - 1]);
                subArrOut.setBuffer(reinterpret_cast<T*>(output.getBuffer()) + tadOut.tadOffsets[outIdx + leftOffset -
j]); subArrOut.assign(&subArr);
            }
            for(int j = (output.sizeAt(dim) - leftOffset); j < output.sizeAt(dim); ++j) {       // fill right side
                subArr.setBuffer(reinterpret_cast<T*>(output.getBuffer()) + tadOut.tadOffsets[outIdx +
output.sizeAt(dim) + leftOffset - j]); subArrOut.setBuffer(reinterpret_cast<T*>(output.getBuffer()) +
tadOut.tadOffsets[outIdx + j]); subArrOut.assign(&subArr);
            }
            break;
    }
}
 */
/*
    void recursiveLoopForPad(const int mode, NDArray& input, const NDArray& paddings, NDArray& output, std::vector<int>
   dimensions, int dim, int inIdx, int outIdx, NDArray& padValue ) { BUILD_SINGLE_SELECTOR(input.dataType(),
   recursiveLoopForPad_, (mode, input, paddings, output, dimensions, dim, inIdx, outIdx, padValue), SD_COMMON_TYPES);
    }

    BUILD_SINGLE_TEMPLATE(template void recursiveLoopForPad_, (const int mode, NDArray& input, const NDArray& paddings,
   NDArray& output, std::vector<int> dimensions, int dim, int inIdx, int outIdx, NDArray& padValue), SD_COMMON_TYPES);

*/

}  // namespace helpers
}  // namespace ops
}  // namespace sd
#endif