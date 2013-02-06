require 'veewee'
require 'deep_merge'
require 'erb'
require 'digest/md5'

module Bosh::Agent::StemCell

  # The source root is the path to the root directory of
  # the Veewee gem.
  def self.source_root
    @source_root ||= Pathname.new(File.expand_path('../../', __FILE__))
  end

  # This BaseBuilder abstract class represents the base stemcell builder and should be extended by specific stemcell
  # builders for different distributions
  class BaseBuilder

    attr_accessor :name, :infrastructure, :architecture
    attr_accessor :agent_src_path, :agent_version, :bosh_protocol
    attr_accessor :prefix, :target
    attr_accessor :iso, :iso_md5, :iso_filename
    attr_accessor :logger
    attr_accessor :manifest

    # Stemcell builders are initialized with a manifest and a set of options. The options provided are merged with the
    # defaults to allow the end user/developer to specify only the ones that they wish to change and fallback to the defaults.
    #
    # The stemcell builder options are as follows
    #{
    #  :name => 'bosh-stemcell', # Name of the output stemcell
    #  :logger => Logger.new(STDOUT), # The logger instance to use
    #  :target => "bosh-#@type-#@agent_version.tgz", # Target file to generate, by default it will the ./bosh-#@type-#@agent_version.tgz
    #  :infrastructure => 'vsphere', # The target infrastructure, this can be aws||vsphere||openstack
    #  :agent_src_path => './bosh_agent-0.7.0.gem', # The path to the stemcell gem to be installed
    #  :agent_version => '0.7.0', # Agent version
    #  :bosh_protocol => '1', # Bosh protocol version
    #  :architecture => 'x86_64', # The target system architecture
    #  :prefix => `pwd`, # Directory to use as the staging area and where the stemcell will be generated
    #  :iso => nil, # The url from where the builder can download the stemcell
    #  :iso_md5 => nil, # The MD5 hash of the iso
    #  :iso_filename => nil # Optional iso filename to use/search for in the iso folder
    #}
    #
    # The stemcell manifest is as follows
    #{
    # :name => @name, # the bosh stemcell name given as a part of the options[:name]
    # :version => @agent_version, # The agent version
    # :bosh_protocol => @bosh_protocol,
    # :cloud_properties => {
    #    :infrastructure => @infrastructure,
    #    :architecture => @architecture
    #  }
    #}
    def initialize(opts={}, manifest={})
      initialize_instance_vars(opts)
      initialize_manifest(manifest)

      sanity_check
    end

    # This method does the setup, this implementation takes care of copying over the
    # correct definition files, packaging the agent and doing any related setup if needed
    def setup
      copy_definitions
      package_agent
    end

    # This method creates the vm using the #@name as the virtual machine name
    # If an existing VM exists with the same name, it will be deleted.
    def build_vm
      Dir.chdir(@prefix) do
        @logger.info "Building vm #@name"
        unless execute_veewee_cmd "build '#@name' --force --nogui --auto"
          raise "Unable to build vm #@name"
        end

        @logger.info "Export built VM #@name to #@prefix"
        unless Kernel.system "vagrant basebox export '#@name' --force"
          raise "Unable to export VM #@name: vagrant basebox export '#@name'"
        end

        @logger.debug "Sending veewee destroy for #@name"
        execute_veewee_cmd "destroy '#@name' --force --nogui"
      end

    end

    def type
      # FIXME: raise "not implemented"
      "noop"
    end

    # Packages the stemcell contents (defined as the array of file path argument)
    def package_stemcell
      generate_image
      generate_manifest
      generate_pkg_list

      package_files "image", "stemcell.MF", "stemcell_dpkg_l.txt"
    end

    def generate_manifest
      stemcell_mf_path = File.expand_path "stemcell.MF", @prefix
      File.open(stemcell_mf_path, "w") do |f|
        f.write(@manifest.to_yaml)
      end
    end

    def generate_image
      Dir.chdir(@prefix) do
        unless system "tar -xzf #{@name}.box"
          raise "Unable to unpack .box file"
        end

        unless system "tar -czf image *.vmdk *.ovf"
          raise "Unable to create image file from ovf and vmdk"
        end
      end
    end

    def generate_pkg_list
      FileUtils.touch File.join(@prefix, "stemcell_dpkg_l.txt")
    end

    # Main execution method that sets up the directory, builds the VM and packages everything into a stemcell
    def run
      setup
      build_vm
      package_stemcell
    end

    protected

    # Cross-platform way of finding an executable in the $PATH.
    #
    #   which('ruby') #=> /usr/bin/ruby
    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each do |ext|
          exe = "#{path}/#{cmd}#{ext}"
          return exe if File.executable? exe
        end
      end
      return nil
    end

    # Execute the provide veewee command and return the exit status
    #
    # @param [String] command Execute the specified veewee command in @prefix
    # @@return Exitstatus of the Kernel#system command
    def execute_veewee_cmd(command="")
      cmd = "veewee vbox #{command}"
      @logger.debug "Executing: #{cmd}"
      Kernel.system cmd
    end

    # Package all files specified as arguments into a tar. The output file is specified by the :target option
    def package_files(*files)
      files_str = files.join(" ")
      @logger.info "Packaging #{files_str} to #{@target}"

      Dir.chdir(@prefix) do
        unless system "tar -czf #{@target} #{files_str}"
          raise "unable to package #{files_str} into a stemcell"
        end
      end
    end

    private

    # Initialize all the options passed to the builder as instance variables after merging with the default values.
    def initialize_instance_vars(opts)
      @logger = opts[:logger] || Logger.new(STDOUT)
      @name = opts[:name] || DEFAULT_STEMCELL_NAME
      @prefix = opts[:prefix] || Dir.pwd
      @infrastructure = opts[:infrastructure] || DEFAULT_INFRASTRUCTURE
      @architecture = opts[:architecture] || DEFAULT_ARCHITECTURE
      @agent_version = Bosh::Agent::VERSION
      @bosh_protocol = Bosh::Agent::BOSH_PROTOCOL
      @agent_src_path = opts[:agent_src_path] || "./bosh_agent-#{agent_version}.gem"
      @target ||= File.join(@prefix, "bosh-#{type}-#{@agent_version}.tgz")
      @iso = opts[:iso]
      @iso_md5 = opts[:iso_md5]

      if @iso
        unless @iso_md5
          raise "MD5 must be specified is ISO is specified"
        end
        @iso_filename = File.basename @iso
      end
    end

    # Merges the given manifest with the default values and assign it to the @manifest instance variable which is later
    # used to generate the stemcell.MF ( the stemcell manifest) that is put in the generated stemcell archive.
    def initialize_manifest(manifest={})
      # perform a deep_merge of the provided manifest with the defaults
      @manifest = manifest.deep_merge(
        {
          :name => @name,
          :version => @agent_version,
          :bosh_protocol => @bosh_protocol,
          :cloud_properties => {
            :infrastructure => @infrastructure,
            :architecture => @architecture
          }
        }
      )
    end

    def sanity_check
      @logger.info "Sanity check"

      @logger.info "Checking target file: #{@target}..."
      if File.exists? @target
        @logger.warn "Target file #@target exists. Moving old file to #@target.bak."
        FileUtils.mv @target, "#@target.bak"
      end

      @logger.info "Checking agent source: #{@agent_src_path}"
      unless File.exists? @agent_src_path
        raise "Agent source #{@agent_src_path} doens't exist"
      end

      @logger.info "Checking definitions dir..."
      unless Dir.exist? definition_dir
        raise "Definition for '#{type}' does not exist at path '#{definition_dir}'"
      end
    end

    # Packages the agent into a bosh_agent gem and copies it over to definition_dest_dir
    # so that it can be used as a part of the VM building process by veewee (using the definition).
    def package_agent
      @logger.debug "Packaging Bosh Agent to #{definition_dest_dir}/_bosh_agent.gem"
      if File.directory? @agent_src_path
        Dir.chdir(@agent_src_path) do
          unless Kernel.system("gem build bosh_agent.gemspec")
            raise "Unable to build Bosh Agent gem"
          end
        end
        # copy gem to definitions
        FileUtils.mv(File.join(@agent_src_path, "bosh_agent-#@agent_version.gem"), File.join(definition_dest_dir, "_bosh_agent.gem"))
      else
        FileUtils.cp @agent_src_path, File.join(definition_dest_dir, "_bosh_agent.gem")
      end
    end

    # Copies the veewee definition directory from ../templates/#@type to #@prefix/definitions/#@name
    def copy_definitions
      @logger.info "Creating definition dest dir"
      FileUtils.mkdir_p definition_dest_dir

      @logger.info "Copying definition from #{definition_dir} to #{definition_dest_dir}"
      FileUtils.cp_r Dir.glob("#{definition_dir}/*"), definition_dest_dir

      # Compile erb files
      Dir.glob(File.join(definition_dest_dir, '*.erb')) { |erb_file|
        new_file_path = erb_file.gsub(/\.erb$/,'')
        @logger.info "Compiling erb #{erb_file} to #{new_file_path}"

        File.open(new_file_path, "w"){|f|
          f.write(ERB.new(File.read(File.expand_path(erb_file))).result(binding))
          File.delete erb_file
        }
      }

    end

    def definition_dir
      File.join(File.dirname(__FILE__), "..", "..", "templates", type)
    end

    def definition_dest_dir
      File.join(@prefix, "definitions", @name)
    end
  end
end

require 'stemcell/builders/noop'
require 'stemcell/builders/ubuntu'
require 'stemcell/builders/redhat'
require 'stemcell/builders/centos'
