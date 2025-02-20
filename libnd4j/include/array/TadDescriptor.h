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
//  @author raver119@gmail.com
//

#ifndef DEV_TESTS_TADDESCRIPTOR_H
#define DEV_TESTS_TADDESCRIPTOR_H

#include <array/ShapeDescriptor.h>

namespace sd {
class SD_LIB_EXPORT TadDescriptor {
 private:
  ShapeDescriptor _originalShape;

  std::vector<sd::LongType> _axis;

  bool _unitiesInShape;

 public:
  explicit TadDescriptor(const sd::LongType *originalShape, const LongType *dimensions, const int length,
                         const bool keepUnitiesInShape = false);
  explicit TadDescriptor(const ShapeDescriptor &descriptor, const std::vector<LongType> &dimensions,
                         const bool keepUnitiesInShape = false);
  ~TadDescriptor() = default;

  // we use default copy assignment operator
#ifndef __NEC__
  // NCC has issues with copy constructors
  TadDescriptor &operator=(const TadDescriptor &other) = default;
  // we use default move assignment operator
  TadDescriptor &operator=(TadDescriptor &&other) noexcept = default;
  explicit TadDescriptor(const TadDescriptor &other);
#endif

#ifdef __NEC__
  TadDescriptor(TadDescriptor &&rhs) = default;                  // move constructor
  TadDescriptor(const TadDescriptor &rhs) = default;             // copy constructor
  TadDescriptor &operator=(const TadDescriptor &rhs) = default;  // copy assignment operator
#endif

  // equal to operator
  bool operator==(const TadDescriptor &other) const;

  // less than operator
  bool operator<(const TadDescriptor &other) const;

  std::vector<sd::LongType> &axis();
  ShapeDescriptor &originalShape();
  ShapeDescriptor const &originalShapeConst() const;
  bool areUnitiesinShape() const;
};
}  // namespace sd

#ifndef __JAVACPP_HACK__

namespace std {
template <>
class SD_LIB_EXPORT hash<sd::TadDescriptor> {
 public:
  size_t operator()(const sd::TadDescriptor &k) const;
};
}  // namespace std

#endif

#endif  // DEV_TESTS_TADDESCRIPTOR_H
