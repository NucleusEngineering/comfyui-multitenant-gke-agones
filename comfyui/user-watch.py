# Copyright 2025 Google LLC
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
import json
import shutil
import requests
import time
import os
from pathlib import Path


sdk_http_port = os.environ['AGONES_SDK_HTTP_PORT']
mount_dir = '/comfyui_nfs_dir'

if os.path.isdir('/app/ComfyUI/models'):
    shutil.rmtree('/app/ComfyUI/models')

Path(os.path.join(mount_dir, 'models')).mkdir(parents=True, exist_ok=True)
os.symlink(os.path.join(mount_dir, 'models'), '/app/ComfyUI/models', target_is_directory = True)

url = 'http://localhost:' + sdk_http_port + '/watch/gameserver'

while True:
    try:
        r = requests.get(url, stream=True)
        if r.status_code == 200:
            break
    except requests.ConnectionError:
        print("Waiting for Agones SDK... (ConnectionError)")
        pass
    print("Waiting for Agones SDK...")
    time.sleep(1)

if r.encoding is None:
    r.encoding = 'utf-8'

for line in r.iter_lines(decode_unicode=True):
    if line: 
        response = json.loads(line)
        if "user" in response['result']['object_meta']['labels']:
            userid = response['result']['object_meta']['labels']['user']
            print(userid)

            # setup folders here
            if os.path.isdir('/app/ComfyUI/outputs'):
                shutil.rmtree('/app/ComfyUI/outputs')

            Path(os.path.join(mount_dir, userid, 'outputs')).mkdir(parents=True, exist_ok=True)
            os.symlink(os.path.join(mount_dir, userid, 'outputs'), '/app/ComfyUI/outputs', target_is_directory = True)

            if os.path.isdir('/app/ComfyUI/output'):
                shutil.rmtree('/app/ComfyUI/output')

            Path(os.path.join(mount_dir, userid, 'output')).mkdir(parents=True, exist_ok=True)
            os.symlink(os.path.join(mount_dir, userid, 'output'), '/app/ComfyUI/output', target_is_directory = True)

            if os.path.isdir('/app/ComfyUI/inputs'):
                shutil.rmtree('/app/ComfyUI/inputs')

            Path(os.path.join(mount_dir, userid, 'inputs')).mkdir(parents=True, exist_ok=True)
            os.symlink(os.path.join(mount_dir, userid, 'inputs'), '/app/ComfyUI/inputs', target_is_directory = True)

            break