@rem Licensed to the Apache Software Foundation (ASF) under one
@rem or more contributor license agreements.  See the NOTICE file
@rem distributed with this work for additional information
@rem regarding copyright ownership.  The ASF licenses this file
@rem to you under the Apache License, Version 2.0 (the
@rem "License"); you may not use this file except in compliance
@rem with the License.  You may obtain a copy of the License at
@rem
@rem   http://www.apache.org/licenses/LICENSE-2.0
@rem
@rem Unless required by applicable law or agreed to in writing,
@rem software distributed under the License is distributed on an
@rem "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
@rem KIND, either express or implied.  See the License for the
@rem specific language governing permissions and limitations
@rem under the License.

@rem To run the script:
@rem verify-release-candidate.bat VERSION RC_NUM

@echo on

setlocal ENABLEDELAYEDEXPANSION

if not exist "C:\tmp\" mkdir C:\tmp
if exist "C:\tmp\arrow-verify-release" rd C:\tmp\arrow-verify-release /s /q
if not exist "C:\tmp\arrow-verify-release" mkdir C:\tmp\arrow-verify-release

set _VERIFICATION_DIR=C:\tmp\arrow-verify-release
set _VERIFICATION_DIR_UNIX=C:/tmp/arrow-verify-release
set _VERIFICATION_CONDA_ENV=%_VERIFICATION_DIR%\conda-env
set INSTALL_DIR=%_VERIFICATION_DIR%\install

set VERSION=%1
set RC_NUMBER=%2
set TARBALL_NAME=apache-arrow-%VERSION%.tar.gz
set TARBALL_URL=https://dist.apache.org/repos/dist/dev/arrow/apache-arrow-%VERSION%-rc%RC_NUMBER%/%TARBALL_NAME%

if "%VERSION%"=="" (
    set ARROW_SOURCE=%~dp0..\..\
) else (
    set ARROW_SOURCE=%_VERIFICATION_DIR%\apache-arrow-%1
    if "%RC_NUMBER%"=="" (
        @rem verify a specific git revision
        git clone https://github.com/apache/arrow.git !ARROW_SOURCE!
        git -C !ARROW_SOURCE! checkout %VERSION%
    ) else (
        @rem verify a release candidate tarball
        @rem Requires GNU Wget for Windows
        wget --no-check-certificate -O %TARBALL_NAME% %TARBALL_URL% || exit /B 1
        tar xf %TARBALL_NAME% -C %_VERIFICATION_DIR_UNIX%
    )
    git clone https://github.com/apache/arrow-testing.git !ARROW_SOURCE!\testing
    git clone https://github.com/apache/parquet-testing.git !ARROW_SOURCE!\cpp\submodules\parquet-testing
)

set ARROW_TEST_DATA=!ARROW_SOURCE!\testing\data
set PARQUET_TEST_DATA=!ARROW_SOURCE!\cpp\submodules\parquet-testing\data
set PYTHON=3.8

@rem Using call with conda.bat seems necessary to avoid terminating the batch
@rem script execution
call conda create --no-shortcuts -c conda-forge -f -q -y -p %_VERIFICATION_CONDA_ENV% ^
    --file=!ARROW_SOURCE!\ci\conda_env_cpp.txt ^
    --file=!ARROW_SOURCE!\ci\conda_env_python.txt ^
    git ^
    python=%PYTHON% ^
    || exit /B 1

call activate %_VERIFICATION_CONDA_ENV% || exit /B 1

@rem With MSVC we always bundle a more recent GTest which causes a link conflict
@rem for more context, see https://issues.apache.org/jira/browse/ARROW-15378
call conda remove -y gtest gmock || exit /B 1

set GENERATOR=Visual Studio 15 2017 Win64
set CONFIGURATION=release

pushd !ARROW_SOURCE!

set ARROW_HOME=%INSTALL_DIR%
set PARQUET_HOME=%INSTALL_DIR%
set PATH=%INSTALL_DIR%\bin;%PATH%

@rem Build and test Arrow C++ libraries
mkdir !ARROW_SOURCE!\cpp\build
pushd !ARROW_SOURCE!\cpp\build

@rem This is the path for Visual Studio Community 2017
call "C:\Program Files (x86)\Microsoft Visual Studio\2017\Community\Common7\Tools\VsDevCmd.bat" -arch=amd64

@rem NOTE(wesm): not using Ninja for now to be able to more easily control the
@rem generator used

cmake -G "%GENERATOR%" ^
      -DARROW_BOOST_USE_SHARED=ON ^
      -DARROW_BUILD_STATIC=OFF ^
      -DARROW_BUILD_TESTS=ON ^
      -DARROW_CXXFLAGS="/MP" ^
      -DARROW_DATASET=ON ^
      -DARROW_FLIGHT=ON ^
      -DARROW_MIMALLOC=ON ^
      -DARROW_PARQUET=ON ^
      -DPARQUET_REQUIRE_ENCRYPTION=ON ^
      -DARROW_PYTHON=ON ^
      -DARROW_WITH_BROTLI=ON ^
      -DARROW_WITH_BZ2=ON ^
      -DARROW_WITH_LZ4=ON ^
      -DARROW_WITH_SNAPPY=ON ^
      -DARROW_WITH_ZLIB=ON ^
      -DARROW_WITH_ZSTD=ON ^
      -DCMAKE_BUILD_TYPE=%CONFIGURATION% ^
      -DCMAKE_INSTALL_PREFIX=%ARROW_HOME% ^
      -DCMAKE_UNITY_BUILD=ON ^
      ..  || exit /B

cmake --build . --target INSTALL --config Release || exit /B 1

@rem Needed so python-test.exe works
set PYTHONPATH_ORIGINAL=%PYTHONPATH%
set PYTHONPATH=%CONDA_PREFIX%\Lib;%CONDA_PREFIX%\Lib\site-packages;%CONDA_PREFIX%\DLLs;%CONDA_PREFIX%;%PYTHONPATH%
ctest -VV  || exit /B 1
set PYTHONPATH=%PYTHONPATH_ORIGINAL%
popd

@rem Build and import pyarrow
pushd !ARROW_SOURCE!\python

pip install -r requirements-test.txt || exit /B 1

set PYARROW_CMAKE_GENERATOR=%GENERATOR%
set PYARROW_WITH_FLIGHT=1
set PYARROW_WITH_PARQUET=1
set PYARROW_WITH_PARQUET_ENCRYPTION=1
set PYARROW_WITH_DATASET=1
python setup.py build_ext --inplace --bundle-arrow-cpp bdist_wheel || exit /B 1
pytest pyarrow -v -s --enable-parquet || exit /B 1

popd

call deactivate
