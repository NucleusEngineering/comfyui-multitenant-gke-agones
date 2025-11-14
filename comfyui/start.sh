#!/bin/bash
# Copyright 2025 Google LLC All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

EXTRA_ARGS=""
if [ "$1" == "--cpu" ]; then
    echo "Starting with CPU support only"
    EXTRA_ARGS="--cpu"
fi

if [ "$1" == "--gpu" ]; then
    echo "Starting with GPU support"
    EXTRA_ARGS=""
fi

conda run --no-capture-output -n comfyui python user-watch.py &
conda run --no-capture-output -n comfyui python /app/ComfyUI/main.py --listen 0.0.0.0 $EXTRA_ARGS