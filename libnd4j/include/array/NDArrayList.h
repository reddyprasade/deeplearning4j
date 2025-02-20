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
// This class describes collection of NDArrays
//
// @author raver119!gmail.com
//

#ifndef NDARRAY_LIST_H
#define NDARRAY_LIST_H
#include <array/NDArray.h>
#include <memory/Workspace.h>
#include <system/common.h>

#include <atomic>
#include <string>
#include <unordered_map>

namespace sd {
class SD_LIB_EXPORT NDArrayList {
 private:
  // workspace where chunks belong to
  // sd::memory::Workspace* _workspace = nullptr;
  sd::LaunchContext *_context = sd::LaunchContext ::defaultContext();

  // numeric and symbolic ids of this list
  std::pair<int, int> _id;
  std::string _name;

  sd::DataType _dtype;

  // stored chunks
  SD_MAP_IMPL<int, sd::NDArray *> _chunks;

  // just a counter, for stored elements
  std::atomic<int> _elements;
  std::atomic<int> _counter;

  // reference shape
  std::vector<sd::LongType> _shape;

  // unstack axis
  int _axis = 0;

  //
  bool _expandable = false;

  // maximum number of elements
  int _height = 0;

 public:
  NDArrayList(int height, bool expandable = false);
  ~NDArrayList();

  sd::DataType dataType();

  NDArray *remove(int idx);
  NDArray *read(int idx);
  NDArray *readRaw(int idx);
  sd::Status write(int idx, NDArray *array);

  NDArray *pick(std::initializer_list<LongType> indices);
  NDArray *pick(std::vector<LongType> &indices);
  bool isWritten(int index);

  std::vector<sd::LongType> &shape();

  NDArray *stack();
  void unstack(NDArray *array, int axis);

  std::pair<int, int> &id();
  std::string &name();
  // sd::memory::Workspace* workspace();
  sd::LaunchContext *context();
  NDArrayList *clone();

  bool equals(NDArrayList &other);

  int elements();
  int height();

  int counter();
};
}  // namespace sd

#endif
