require 'rake/tasklib'
require 'ostruct'
require 'fileutils'
require 'cfpropertylist'
require 'beta_builder/archived_build'
require 'beta_builder/deployment_strategies'

module BetaBuilder
  class Tasks < ::Rake::TaskLib
    def initialize(namespace = :beta, &block)
      @configuration = Configuration.new(
        :configuration => "Adhoc",
        :build_dir => "build",
        :auto_archive => false,
        :archive_path  => File.expand_path("~/Library/Developer/Xcode/Archives"),
        :xcodebuild_path => "xcodebuild",
        :project_file_path => nil,
        :workspace_path => nil,
        :package_file_base_path => nil,
        :scheme => nil,
        :app_name => nil,
        :arch => nil,
        :xcode4_archive_mode => false,
        :skip_clean => false,
        :verbose => false,
        :dry_run => false
      )
      @namespace = namespace
      yield @configuration if block_given?
      define
    end

    def xcodebuild(*args)
      # we're using tee as we still want to see our build output on screen
      system("#{@configuration.xcodebuild_path} #{args.join(" ")} | tee build.output")
    end

    class Configuration < OpenStruct
      def release_notes_text
        return release_notes.call if release_notes.is_a? Proc
        release_notes
      end
      def build_arguments
        args = ""
        if workspace_path
          raise "A scheme is required if building from a workspace" unless scheme
          args << "-workspace '#{workspace_path}' -scheme '#{scheme}' -configuration '#{configuration}'"
        else
          args = "-target '#{target}' -configuration '#{configuration}' -sdk iphoneos"
          args << " -project #{project_file_path}" if project_file_path
        end

        args << " -arch \"#{arch}\"" unless arch.nil?

        args
      end

      def archive_name
        app_name || target
      end
      
      def app_file_name
        raise ArgumentError, "app_name or target must be set in the BetaBuilder configuration block" if app_name.nil? && target.nil?
        if app_name
          "#{app_name}.app"
        else
          "#{target}.app"
        end
      end
      
      def ipa_name
        if app_name
          "#{app_name}.ipa"
        else
          "#{target}.ipa"
        end
      end
      
      def built_app_path
        if build_dir == :derived
          "#{derived_build_dir_from_build_output}/#{configuration}-iphoneos/#{app_file_name}"
        else
          "#{build_dir}/#{configuration}-iphoneos/#{app_file_name}"
        end
      end
      
      def derived_build_dir_from_build_output
        output = File.read("build.output")
        
        # yes, this is truly horrible, but unless somebody else can find a better way...
        found = output.split("\n").grep(/^Validate(.*)\/Xcode\/DerivedData\/(.*)-(.*)/).first
        if found && found =~ /Validate \"(.*)\"/
            reference = $1 
        else 
            raise "Cannot parse build_dir from build output."
        end        
        derived_data_directory = reference.split("/Build/Products/").first
        "#{derived_data_directory}/Build/Products/"
      end
      
      def built_app_dsym_path
        "#{built_app_path}.dSYM"
      end
      
      def dist_path
        File.join("pkg/dist")
      end
      
      def ipa_path
        File.join(dist_path, ipa_name)
      end
      
      def deploy_using(strategy_name, &block)
        if DeploymentStrategies.valid_strategy?(strategy_name.to_sym)
          self.deployment_strategy = DeploymentStrategies.build(strategy_name, self)
          self.deployment_strategy.configure(&block)
        else
          raise "Unknown deployment strategy '#{strategy_name}'."
        end
      end
    end
    
    private
    
    def define
      namespace(@namespace) do
        desc "Build the beta release of the app"
        task :build => :clean do
          xcodebuild @configuration.build_arguments, "build"
        end
        
        task :clean do
          unless @configuration.skip_clean
            xcodebuild @configuration.build_arguments, "clean"
          end
        end
        
        desc "Package the beta release as an IPA file"
        task :package => :build do
          if @configuration.auto_archive
            Rake::Task["#{@namespace}:archive"].invoke
          end
          
					if @configuration.package_file_base_path
						filePath = @configuration.package_file_base_path.to_s + "/" + @namespace.to_s
						FileUtils.rm_f(filePath) && FileUtils.mkdir_p("#{@configuration.package_file_base_path}")
					else
						FileUtils.rm_rf('pkg') && FileUtils.mkdir_p('pkg')	
					end          
          
          system("/usr/bin/xcrun -sdk iphoneos PackageApplication -v '#{@configuration.built_app_path}' -o '/tmp/#{@configuration.ipa_name}' --sign '#{@configuration.signing_identity}' --embed #{@configuration.provisioning_profile}")

					if @configuration.package_file_base_path
						filePath = @configuration.package_file_base_path.to_s + "/" + @namespace.to_s
						unless File.exist?(filePath)
							FileUtils.mkdir(filePath)	
						end
	          FileUtils.mv("/tmp/#{@configuration.ipa_name}", filePath)						
					else
	          FileUtils.mkdir('pkg/dist')
	          FileUtils.mv("/tmp/#{@configuration.ipa_name}", "pkg/dist")
					end          
        end
        
        if @configuration.deployment_strategy
          desc "Prepare your app for deployment"
          task :prepare => :package do
            @configuration.deployment_strategy.prepare
          end
          
          desc "Deploy the beta using your chosen deployment strategy"
          task :deploy => :prepare do
            @configuration.deployment_strategy.deploy
          end
          
          desc "Deploy the last build"
          task :redeploy do
            @configuration.deployment_strategy.prepare
            @configuration.deployment_strategy.deploy
          end
        end
        
        desc "Build and archive the app"
        task :archive => :build do
          puts "Archiving build..."
          archive = BetaBuilder.archive(@configuration)
          output_path = archive.save_to(@configuration.archive_path)
          puts "Archive saved to #{output_path}."
        end
      end
    end
  end
end
