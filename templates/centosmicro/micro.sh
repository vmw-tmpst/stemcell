#!/bin/bash

source _variables.sh

blobstore_path=${bosh_app_dir}/micro_bosh/data/cache
agent_host=localhost
agent_port=6969
agent_uri=http://vcap:vcap@${agent_host}:${agent_port}
export PATH=${bosh_app_dir}/bosh/bin:$PATH

# Packages
apt-get -y install genisoimage libpq-dev

# Install package compiler
mkdir -p /tmp/package_compiler
pushd /tmp/package_compiler
    cp $SRC_DIR/_package_compiler.tar .
    tar -xvf _package_compiler.tar
    $bosh_dir/bin/gem install agent_client*.gem --no-ri --no-rdoc --local
    $bosh_dir/bin/gem install bosh_common*.gem --no-ri --no-rdoc --local
    $bosh_dir/bin/gem install blobstore_client*.gem --no-ri --no-rdoc --local

    # TODO: Not sure why but w/o this package_compiler does not install trollop-1.16.x
    $bosh_dir/bin/gem install trollop --no-ri --no-rdoc --local
    $bosh_dir/bin/gem install package_compiler*.gem --no-ri --no-rdoc --local
popd

mkdir -p ${bosh_app_dir}/bosh/blob
mkdir -p ${blobstore_path}

echo "Starting micro bosh compilation"

# Start agent
$bosh_dir/bin/bosh_agent -I ${infrastructure} -n ${agent_uri} -s ${blobstore_path} -p local &
agent_pid=$!

# Wait for agent to come up
for i in {1..10}
  do
    nc -z ${agent_host} ${agent_port} && break
    sleep 1
  done

# Start compiler
$bosh_dir/bin/package_compiler --cpi ${infrastructure} compile $SRC_DIR/_release.yml $SRC_DIR/_release.tgz ${blobstore_path} ${agent_uri}

kill -15 $agent_pid

# Wait for agent
for i in {1..5}
do
  kill -0 $agent_pid && break
  sleep 1
done
# Force kill if required
kill -0 $agent_pid || kill -9 $agent_pid
