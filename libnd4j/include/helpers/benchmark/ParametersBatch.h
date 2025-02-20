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
// @author raver119@gmail.com
//

#ifndef DEV_TESTS_PARAMETERSBATCH_H
#define DEV_TESTS_PARAMETERSBATCH_H
#include <helpers/benchmark/ParametersSpace.h>
#include <helpers/shape.h>

#include <vector>

namespace sd {
class ParametersBatch {
 protected:
  std::vector<ParametersSpace*> _spaces;

 public:
  ParametersBatch() = default;
  ParametersBatch(std::initializer_list<ParametersSpace*> spaces) { _spaces = spaces; }

  ParametersBatch(std::vector<ParametersSpace*> spaces) { _spaces = spaces; }

  std::vector<Parameters> parameters() {
    std::vector<Parameters> result;
    std::vector<std::vector<sd::LongType>> vectors;
    int totalIterations = 1;

    // hehe
    sd::LongType xCoords[SD_MAX_RANK];
    sd::LongType xShape[SD_MAX_RANK];
    sd::LongType xRank = _spaces.size();

    for (int e = 0; e < _spaces.size(); e++) {
      auto space = _spaces[e];
      auto values = space->evaluate();
      vectors.emplace_back(values);

      totalIterations *= values.size();
      xShape[e] = values.size();
    }

    // sd_printf("Total Iterations: %i\n", totalIterations);

    for (int i = 0; i < totalIterations; i++) {
      if (xRank > 0) shape::index2coords(i, xRank, xShape, xCoords);

      Parameters params;
      for (int j = 0; j < xRank; j++) {
        int value = vectors[j][xCoords[j]];
        std::string name = _spaces[j]->name();
        params.addIntParam(name, value);
      }

      result.emplace_back(params);
    }

    return result;
  }
};
}  // namespace sd

#endif  // DEV_TESTS_PARAMETERSBATCH_H
