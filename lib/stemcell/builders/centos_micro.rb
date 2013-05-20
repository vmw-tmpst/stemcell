require 'stemcell/builders/centos'

module Bosh::Agent::StemCell

  # This is concrete Stemcell builder for creating a Centos micro-bosh stemcell
  # It creates a CentOS-6.3. The options passed are merged with
  # {
  #   :type => 'centos',
  #   :iso => 'http://www.mirrorservice.org/sites/mirror.centos.org/6.3/isos/x86_64/CentOS-6.3-x86_64-minimal.iso',
  #   :iso_md5 => '087713752fa88c03a5e8471c661ad1a2',
  #   :iso_filename => 'CentOS-6.3-x86_64-minimal.iso'
  # }
  class MicroCentosBuilder < CentosBuilder

    def type
      "centosmicro"
    end

    def initialize(opts)
      #@bosh_src_root = opts[:bosh_src_root] || File.expand_path("bosh", @prefix)
      @release_manifest = opts[:release_manifest] # || default_release_manifest
      @release_tar = opts[:release_tar]
                                                  # This is kind of a hack :(
      if opts[:package_compiler_tar] && File.directory?(opts[:package_compiler_tar])
        # Tar up the package
        tmpdir = Dir.mktmpdir
        tmp_package_compiler_tar = File.join(tmpdir, "_package_compiler.tar")
        Dir.chdir(opts[:package_compiler_tar]) do
          sh "tar -cf #{tmp_package_compiler_tar} *"
          @package_compiler_tar = tmp_package_compiler_tar
        end
      else
        @package_compiler_tar = File.expand_path(opts[:package_compiler_tar])
      end

      unless File.exists?(@release_manifest) && File.exists?(@release_tar) && File.exists?(@package_compiler_tar)
        raise "Please confirm #@release_tar, #@release_manifest and #@package_compiler_tar exists."
      end
      super(opts)
    end

    def setup
      # Do all the usual things
      super()
      FileUtils.cp @package_compiler_tar, File.join(definition_dest_dir, "_package_compiler.tar")
      FileUtils.cp @release_tar, File.join(definition_dest_dir, "_release.tgz")
      FileUtils.cp @release_manifest, File.join(definition_dest_dir, "_release.yml")
    end

    def build_all_deps
      @logger.info "Build all bosh packages with dependencies from source"
      @logger.info "Execute 'rake all:build_with_deps' in bosh/ directory"
    end

    def create_release_tarball
      @logger.info("Copy bosh/release/config/microbosh-dev-template.yml to bosh/release/config/dev.yml")
      @logger.info("Then execute 'bosh create release --force --with-tarball'")
      @logger.info("The release tar will be in bosh/release/dev_releases/micro-bosh*.tgz")
    end

    def pre_shutdown_hook
      ssh_download_file("/var/vcap/bosh/stemcell_yum_list_installed.out", File.join(@prefix, "stemcell_yum_list_installed.out"))
      ssh_download_file("/var/vcap/micro/apply_spec.yml", File.join(@prefix, "apply_spec.yml"))
    end

    def stemcell_files
      [File.join(@prefix, "stemcell_yum_list_installed.out"), File.join(@prefix, "apply_spec.yml")]
    end
  end

end
