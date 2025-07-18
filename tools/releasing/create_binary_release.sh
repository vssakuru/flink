#!/usr/bin/env bash

#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

##
## Variables with defaults (if not overwritten by environment)
##
SKIP_GPG=${SKIP_GPG:-false}
MVN=${MVN:-mvn}

if [ -z "${RELEASE_VERSION:-}" ]; then
    echo "RELEASE_VERSION was not set."
    exit 1
fi

# fail immediately
set -o errexit
set -o nounset
# print command before executing
set -o xtrace

CURR_DIR=`pwd`
if [[ `basename $CURR_DIR` != "tools" ]] ; then
  echo "You have to call the script from the tools/ dir"
  exit 1
fi

if [ "$(uname)" == "Darwin" ]; then
    SHASUM="shasum -a 512"
else
    SHASUM="sha512sum"
fi

cd ..

FLINK_DIR=`pwd`
RELEASE_DIR=${FLINK_DIR}/tools/releasing/release
PYTHON_RELEASE_DIR=${RELEASE_DIR}/python
mkdir -p ${PYTHON_RELEASE_DIR}

###########################

# build maven package, create Flink distribution, generate signature
make_binary_release() {
  local DEFAULT_SCALA_VERSION
  DEFAULT_SCALA_VERSION="2.12"
  echo "Creating binary release"
  # the scala version is still included in the name to not break "backwards-compatibility" of the naming scheme
  dir_name="flink-$RELEASE_VERSION-bin-scala_${DEFAULT_SCALA_VERSION}"

  # enable release profile here (to check for the maven version)
  $MVN clean package -Prelease -pl flink-dist -am -Dgpg.skip -Dcheckstyle.skip=true -DskipTests

  cd flink-dist/target/flink-${RELEASE_VERSION}-bin
  ${FLINK_DIR}/tools/releasing/collect_license_files.sh ./flink-${RELEASE_VERSION} ./flink-${RELEASE_VERSION}
  tar czf "${dir_name}.tgz" flink-*

  cp flink-*.tgz ${RELEASE_DIR}
  cd ${RELEASE_DIR}

  # Sign sha the tgz
  if [ "$SKIP_GPG" == "false" ] ; then
    gpg --armor --detach-sig "${dir_name}.tgz"
  fi
  $SHASUM "${dir_name}.tgz" > "${dir_name}.tgz.sha512"

  cd ${FLINK_DIR}
}

make_python_release() {
  PYFLINK_VERSION=${RELEASE_VERSION/-SNAPSHOT/.dev0}
  cd flink-python/
  # use lint-python.sh script to create a python environment.
  dev/lint-python.sh -s basic
  source dev/.uv/bin/activate
  uv pip install --group dev

  # build apache-flink-libraries sdist
  pushd apache-flink-libraries
  python setup.py sdist
  pushd dist/
  apache_flink_libraries_actual_name=`echo *.tar.gz`
  apache_flink_libraries_release_name="apache_flink_libraries-${PYFLINK_VERSION}.tar.gz"

  if [[ "$apache_flink_libraries_actual_name" != "$apache_flink_libraries_release_name" ]] ; then
    echo -e "\033[31;1mThe file name of the python package: ${apache_flink_libraries_actual_name} is not consistent with given release version: ${PYFLINK_VERSION}!\033[0m"
    exit 1
  fi

  cp ${apache_flink_libraries_actual_name} "${PYTHON_RELEASE_DIR}/${apache_flink_libraries_release_name}"

  popd

  popd

  python setup.py sdist
  deactivate
  cd dist/
  pyflink_actual_name=`echo *.tar.gz`
  pyflink_release_name="apache_flink-${PYFLINK_VERSION}.tar.gz"

  if [[ "$pyflink_actual_name" != "$pyflink_release_name" ]] ; then
    echo -e "\033[31;1mThe file name of the python package: ${pyflink_actual_name} is not consistent with given release version: ${PYFLINK_VERSION}!\033[0m"
    exit 1
  fi

  cp ${pyflink_actual_name} "${PYTHON_RELEASE_DIR}/${pyflink_release_name}"

  wheel_packages_num=0
  # py39,py310,py311,py312 for mac 10.9, 11.0 and linux (12 wheel packages)
  EXPECTED_WHEEL_PACKAGES_NUM=12
  # Need to move the downloaded wheel packages from Azure CI to the directory flink-python/dist manually.
  for wheel_file in *.whl; do
    if [[ ! ${wheel_file} =~ ^apache_flink-$PYFLINK_VERSION- ]]; then
        echo -e "\033[31;1mThe file name of the python package: ${wheel_file} is not consistent with given release version: ${PYFLINK_VERSION}!\033[0m"
        exit 1
    fi
    cp ${wheel_file} "${PYTHON_RELEASE_DIR}/${wheel_file}"
    wheel_packages_num=$((wheel_packages_num+1))
  done
  if [[ ${wheel_packages_num} != ${EXPECTED_WHEEL_PACKAGES_NUM} ]]; then
    echo -e "\033[31;1mThe number of wheel packages ${wheel_packages_num} is not equal to the expected number ${EXPECTED_WHEEL_PACKAGES_NUM}!\033[0m"
    exit 1
  fi

  cd ${PYTHON_RELEASE_DIR}

  # Sign sha the tgz and wheel packages
  if [ "$SKIP_GPG" == "false" ] ; then
    gpg --armor --detach-sig "${apache_flink_libraries_release_name}"
    gpg --armor --detach-sig "${pyflink_release_name}"
    for wheel_file in *.whl; do
      gpg --armor --detach-sig "${wheel_file}"
    done
  fi
  $SHASUM "${apache_flink_libraries_release_name}" > "${apache_flink_libraries_release_name}.sha512"
  $SHASUM "${pyflink_release_name}" > "${pyflink_release_name}.sha512"

  for wheel_file in *.whl; do
    $SHASUM "${wheel_file}" > "${wheel_file}.sha512"
  done

  cd ${FLINK_DIR}
}

make_binary_release
make_python_release
