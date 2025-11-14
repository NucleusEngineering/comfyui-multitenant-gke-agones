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
FROM openresty/openresty:1.21.4.1-0-focal

RUN opm get ledgetech/lua-resty-http
RUN opm get openresty/lua-resty-redis
RUN opm get openresty/lua-resty-dns

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf
COPY comfyui.lua /usr/local/openresty/nginx/comfyui.lua
COPY index.html  /usr/local/openresty/nginx/html/index.html
COPY error.html  /usr/local/openresty/nginx/html/error.html