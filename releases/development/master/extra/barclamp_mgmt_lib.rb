#!/usr/bin/env ruby
# Copyright 2012, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#

require 'rubygems'
require 'yaml'
require 'json'
require 'fileutils'
require 'pp'

MODEL_SUBSTRING_BASE = '==BC-MODEL=='
MODEL_SUBSTRING_CAMEL = '==^BC-MODEL=='
MODEL_SUBSTRING_HUMAN = '==*BC-MODEL=='
MODEL_SUBSTRING_CAPSS = '==%BC-MODEL=='

def update_paths
  @BASE_PATH = @@base_dir
  @CROWBAR_PATH = File.join @BASE_PATH, 'crowbar_framework'
  if ENV["CROWBAR_DIR"]
    @MODEL_SOURCE = File.join ENV["CROWBAR_DIR"], "barclamps","crowbar","crowbar_framework",'barclamp_model'
    @BARCLAMP_PATH = File.join ENV["CROWBAR_DIR"], "barclamps"
  else
    @BARCLAMP_PATH = File.join @BASE_PATH, 'barclamps'
    @MODEL_SOURCE = File.join @CROWBAR_PATH, 'barclamp_model'
  end
  @BIN_PATH = File.join @BASE_PATH, 'bin'
  @SETUP_PATH = File.join @BASE_PATH, 'setup'
  @UPDATE_PATH = '/updates'
  @ROOT_PATH = '/'
end

@@debug = ENV['DEBUG'] === "true"
@@base_dir = "/opt/dell"
@@deploy = false
@@no_install_actions = false
@@no_migrations = false
@@no_chef = false
@@no_files = false

def debug(msg)
  puts "DEBUG: " + msg if @@debug
end

def fatal(msg, log=nil)
  m = "ERROR: #{msg}  Aborting"
  m ="#{m}; examine #{log} for more info."  if log
  puts m
  exit 1
end

# entry point for scripts
def bc_install(bc, bc_path, yaml)
  case yaml["crowbar"]["layout"].to_s
  when "1"
    throw "ERROR: Crowbar 1.x barclamp formats (#{bc}) are not supported in Crowbar 2.x"
  when "1.9","2"
    debug "Installing app components"
    bc_install_layout_2_app bc, bc_path, yaml unless @@deploy
    debug "Running database migrations" unless @@no_migrations
    bc_install_layout_2_migrations bc, bc_path, yaml unless @@no_migrations
    debug "Installing chef components" unless @@no_chef
    bc_install_layout_1_chef bc, bc_path, yaml unless @@no_chef
    debug "Installing cache components" unless @@no_files
    bc_install_layout_1_cache bc, bc_path unless @@no_files
    debug "Performing install actions" unless @@no_install_actions
    bc_do_install_action bc, bc_path, :install unless @@no_install_actions
  else
    throw "ERROR: could not install barclamp #{bc} because #{barclamp["barclamp"]["crowbar_layout"]} is unknown layout."
  end
  catalog bc_path
end

# regenerate the barclamp catalog (LEGACY - no longer generated catalog)
def catalog(bc_path)
  debug "Copying barclamp 1.x meta_data from #{bc_path}"
  # create the groups for the catalog - for now, just groups.  other catalogs may be added later
  barclamps = File.join @CROWBAR_PATH, 'barclamps'
  system("knife data bag create -k /etc/chef/webui.pem -u chef-webui barclamps") unless @@no_chef
  list = Dir.entries(barclamps).find_all { |e| e.end_with? '.yml'}
  # scan the installed barclamps
  list.each do |bc_file|
    Dir.mkdir("#{barclamps}/bc_meta") unless File.directory?("#{barclamps}/bc_meta")
    debug "Loading #{bc_file}"
    bc = YAML.load_file File.join(barclamps, bc_file)
    File.open("#{barclamps}/bc_meta/#{bc_file}.json","w+") { |f|
      f.truncate(0)
      bc["id"] = bc_file.split('.')[0]
      f.puts(JSON.pretty_generate(bc))
    }
    Kernel.system("knife data bag from file -k /etc/chef/webui.pem -u chef-webui barclamps \"#{barclamps}/bc_meta/#{bc_file}.json\"") unless @@no_chef
  end
end


# copies paths from one place to another (recursive)
def bc_cloner(item, bc, entity, source, target, replace)
  # Replace: ONLY used when creating a new barclamp from the model!
  debug "bc_cloner method called with debug option enabled"
  debug "bc_cloner args: item=#{item}, bc=#{bc}, entity=#{entity}, source=#{source}, target=#{target}, replace=#{replace}"

  files = []
  new_item = (replace ? bc_replacer("#{item}", bc, entity) : item)
  new_file = File.join target, new_item
  new_source = File.join(source, item)
  debug "\tnew_source=#{new_source}"
  debug "\tnew_target=#{new_file} (item is #{new_item})"
  if File.directory? new_source
    debug "\tcreating directory #{new_file}."
    FileUtils.mkdir new_file unless File.directory? new_file
    clone = Dir.entries(new_source).find_all { |e| !e.start_with? '.'}
    clone.each do |recurse|
      files += bc_cloner(recurse, bc, entity, new_source, new_file, replace)
    end
  else
    #need to inject into the file (normal copy)
    unless replace
      debug "\t\tcopying file to #{new_file}."
      FileUtils.cp new_source, new_file
      files << new_file
    #we need to scrub the file for replacement strings
    else
      debug "\t\tcreating file #{new_file}."
      t = File.open(new_file, 'w')
      File.open(new_source, 'r') do |f|
        s = f.read
        t.write(bc_replacer(s, bc, entity))
      end
      t.close
      files << new_file
    end
  end
  return files
end

# fix permissions
def chmod_dir(value, path)
  f = Dir.entries(path).find_all { |e| !e.start_with? '.'}
  f.each do |i|
    file = File.join(path,i)
    if File.exists? file
      FileUtils.chmod value, file
      debug "\tchmod 0#{value.to_s(8)} for #{file}"
    else
      puts "WARN: missing file #{file} for chmod #{value} operation."
    end
  end
end

# remove model placeholders
def bc_replacer(item, bc, entity)
  debug "bc_replacer method called with debug option enabled"
  debug "bc_replacer args: item=#{item}, bc=#{bc}, entity=#{entity}"

  item.gsub!(MODEL_SUBSTRING_BASE, bc)
  item.gsub!(MODEL_SUBSTRING_CAMEL, bc.camelize)
  item.gsub!(MODEL_SUBSTRING_HUMAN, bc.humanize)
  item.gsub!(MODEL_SUBSTRING_CAPSS, bc.capitalize)
  item.gsub!('Copyright 2012, Dell', "Copyright #{Time.now.year}, #{entity}")
  debug "bc_replacer returns item=#{item}"
  return item
end

# makes sure that sass overrides are injected into the application.sass
def merge_sass(yaml, bc, path, installing)
  sass_path = File.join path, 'crowbar_framework', 'app', 'assets', 'stylesheets'
  application_sass = File.join @CROWBAR_PATH, 'app', 'assets', 'stylesheets', 'application.sass'
  if File.exist? application_sass and File.exists? sass_path
    sass_files = Dir.entries(sass_path).find_all { |r| r =~ /^_(.*).sass$/ }
    # get entries from the applicaiton.sass file
    sapp = []
    File.open(application_sass,'r') do |f|
      f.each_line { |l| sapp << l.chomp }
    end
    # figure out where to insert the sass item
    top = -1
    if !yaml['application_sass'].nil? and  yaml['application_sass']['add'] === 'top'
      top = (sapp.find_index("// top of import list") || 3)+1
    end
    # remove items that we don't want
    yaml['application_sass']['remove'].each do |item|
      if installing and sapp.include? item
        sapp.delete item
        debug "removing '#{item}' from application.sass based on crowbar.yml"
      elsif !installing and !sapp.include? item
        if top>0
          sapp.insert top, item
        else
          sapp << item
        end
        debug "restoring '#{item}' to application.sass based on crowbar.yml in position #{top}"
      end
    end unless yaml['application_sass'].nil? or yaml['application_sass']['remove'].nil?
    # scan the sass files from the barclamp
    sass_files.each do |sf|
      entry = "@import #{sf[/^_(.*).sass$/,1]}"
      # when installing, if not already in the application, add it
      if installing and !sapp.include? entry
        if top>0
          sapp.insert top, entry
        else
          sapp << entry
        end
        debug "adding '#{entry}' to application.sass for #{sf} in position #{top}"
        # when uninstalling, remove from applicaiton
      elsif !installing
        sapp.delete entry
        debug "removing '#{entry}' from application.sass for #{sf}"
      end
    end
    # write the new application sass
    File.open(application_sass, 'w' ) do |out|
      out.puts sapp
    end
    framework_permissions bc, path

    debug "updated #{application_sass}"
  else
    debug "NOTE: skipping application sass update, #{application_sass} not found"
  end
end

def framework_permissions(bc, bc_path)
  if File.exists?(File.join(@CROWBAR_PATH, 'db'))
    FileUtils.chmod 0755, File.join(@CROWBAR_PATH, 'db')
    chmod_dir 0644, File.join(@CROWBAR_PATH, 'db')
    FileUtils.chmod 0755, File.join(@CROWBAR_PATH, 'db', 'migrate')
  end
  if File.exists?(File.join(@CROWBAR_PATH, 'tmp'))
    FileUtils.chmod 0755, File.join(@CROWBAR_PATH, 'tmp')
    chmod_dir 0644, File.join(@CROWBAR_PATH, 'tmp')
  end
  debug "\tcopied crowbar_framework files"
end


# perform install actions for the barclamp
# look for setup/* files and execute the appropriate ones, in order, based on
# the lifecycle stage the barclap is going through :
#  :install - IXXX
#  :update - UXXX
#
# The XXX is sorted, and the scripts are executed in order.
# The crowbar reserves the ranges 0-9 and 50-9.
# Other params:
#   bc - the barclamps name
def bc_do_install_action(bc, bc_path, stage)
  setup_target = File.join(@SETUP_PATH,bc)
  suffix = ""
  case stage
  when :install then suffix="install"
  when :remove then  suffix="remove"
  else
    fatal("unknown barclamp lifecycle stage: #{stage}")
  end
  actions = []
  Dir.glob(File.join(setup_target,"*.#{suffix}")) { |x| actions << x}
  actions.sort!
  debug("actions to perform: #{actions.join(' ')}")
  actions.each { |action| 
    fatal("action #{action} not found for #{bc}") unless File.exists?(action)
    output = `CROWBAR_DIR=#{@@base_dir} BC_PATH=#{bc_path} #{action} 2>&1`
    fatal("action #{action} failed for #{bc}:\n #{output}") unless $? == 0
    debug("install action:#{action} output: #{output}")
  }   
end

def camelize(str)
  str.split('_').map {|w| w.capitalize}.join
end

# install the framework files for a barclamp
def bc_install_layout_2_app(bc, bc_path, yaml)

  #TODO - add a roll back so there are NOT partial results if a step fails
  files = []

  puts "Installing barclamp #{bc} from #{bc_path}"

  #copy the rails parts (required for render BEFORE import into chef)
  dirs = Dir.entries(bc_path)
  debug "path entries #{dirs.pretty_inspect}"

  if dirs.include? 'crowbar_engine'
    debug "path entries include \"crowbar_engine\""
    system "perl -pi -e 's|engine mounts|engine mounts\n  mount Barclamp" + camelize(bc) + "::Engine, :at => \"" + bc + "\"|' " + @BASE_PATH + "/crowbar_framework/config/routes.rb"
    system "perl -pi -e 's|engine mounts|engine mounts\ngem \"barclamp_" + bc + "\", :path => \"" + bc_path + "/crowbar_engine/barclamp_" + bc + "\"|' " + @BASE_PATH + "/crowbar_framework/Gemfile" 

  elsif dirs.include? 'crowbar_framework'
    debug "path entries include \"crowbar_framework\""
    files += bc_cloner('crowbar_framework', bc, nil, bc_path, @BASE_PATH, false)
    framework_permissions bc, bc_path
  end

  # TODO: going away for 2.0, we think
  #debug "merge_sass"
  #merge_sass yaml, bc, bc_path, true

  if dirs.include? 'bin'
    debug "path entries include \"bin\""
    files += bc_cloner('bin', bc, nil, bc_path, @BASE_PATH, false)
    FileUtils.chmod_R 0755, @BIN_PATH
    debug "\tcopied files for #{@BIN_PATH}"
  end

  # copy over install-actions
  if dirs.include? 'setup'
    setup_source = File.join(bc_path,'setup')
    setup_target = File.join(@SETUP_PATH,bc)
    FileUtils.mkdir @SETUP_PATH unless File.directory? @SETUP_PATH
    FileUtils.mkdir setup_target unless File.directory? setup_target
    debug "Install actions path entries from #{setup_source}/setup to #{setup_target}"
    files += bc_cloner('', bc, nil, setup_source, setup_target, false)
    FileUtils.chmod_R 0755, setup_target
    debug "\tcopied over install actions from #{setup_source}/setup to #{setup_target}"
  else
    debug "\tno install actions to copy"
  end

  if dirs.include? 'updates' and !@@no_files
    debug "path entries include \"updates\""
    files += bc_cloner('updates', bc, nil, bc_path, @ROOT_PATH, false)
    FileUtils.chmod_R 0755, @UPDATE_PATH
    debug "\tcopied updates files"
  end

  # copy all the files to the target
  if dirs.include? 'chef'
    debug "path entries include \"chef\""
    files += bc_cloner('chef', bc, nil, bc_path, @BASE_PATH, false)
    debug "\tcopied over chef parts from #{bc_path} to #{@BASE_PATH}"
  end

  # copy all the BDD files to the target
  if dirs.include? 'BDD'
    debug "path entries include \"BDD\""
    files += bc_cloner('BDD', bc, nil, bc_path, @BASE_PATH, false)
    debug "\tcopied over BDD parts from #{bc_path} to #{@BASE_PATH}"
  end

  # copy over docs
  if dirs.include? 'doc'
    doc_source = File.join(bc_path,'doc')
    doc_target = File.join(@BASE_PATH,'doc',bc)
    FileUtils.mkdir File.join(@BASE_PATH,'doc') unless File.directory? File.join(@BASE_PATH,'doc')
    FileUtils.mkdir doc_target unless File.directory? doc_target
    debug "Doc path entries from #{doc_source} to #{doc_target}"
    files += bc_cloner('', bc, nil, doc_source, doc_target, false)
    debug "\tcopied over Docs from #{doc_source} to #{doc_target}"
  else
    debug "\tno Docs to copy"
  end

  # Migrate base crowbar schema if needed
  bc_schema_version = yaml["crowbar"]["proposal_schema_version"].to_i rescue 1
  if bc_schema_version < 2
    name = yaml['barclamp']['name']
    schema_file = File.join @BASE_PATH, 'chef','data_bags','crowbar', "bc-template-#{name}.schema"
    if File.exists? schema_file
      a = []
      File.open(schema_file, 'r') { |f|
        a = f.readlines
      }

      File.open(schema_file, 'w') { |f|
        a.each do |line|
          if line =~ /crowbar-committing/
            f.write("  \"crowbar-status\": { \"type\": \"str\" },\n")
            f.write("  \"crowbar-failed\": { \"type\": \"str\" },\n")
          end
          f.write(line)
        end
      }
    end
  end

  filelist = File.join @BARCLAMP_PATH, "#{bc}-filelist.txt"
  File.open( filelist, 'w' ) do |out|
    files.each { |line| out.puts line }
  end

  #copy over the crowbar.yml and template file
  yml_path = File.join @CROWBAR_PATH, 'barclamps'
  template_path = File.join yml_path, 'templates'
  schema_path = File.join yml_path, 'schemas'
  yml_barclamp = File.join bc_path, "crowbar.yml"
  template_file = File.join bc_path, "chef", "data_bags", "crowbar", "bc-template-#{bc}.json"
  schema_file = File.join bc_path, "chef", "data_bags", "crowbar", "bc-template-#{bc}.schema"
  new_template_file = File.join bc_path, "chef", "data_bags", "crowbar", "bc-template-#{bc}-new.json"
  FileUtils.mkdir_p yml_path unless File.directory? yml_path
  FileUtils.mkdir_p template_path unless File.directory? template_path
  FileUtils.mkdir_p schema_path unless File.directory? schema_path
  FileUtils.cp yml_barclamp, File.join(yml_path, "#{bc}.yml")
  FileUtils.cp template_file, File.join(template_path, "", "bc-template-#{bc}.json") if File.exists? template_file
  FileUtils.cp schema_file, File.join(schema_path, "", "bc-template-#{bc}.schema") if File.exists? schema_file
  FileUtils.cp new_template_file, File.join(template_path, "", "bc-template-#{bc}-new.json") if File.exists? new_template_file

  bc_layout = yaml["crowbar"]["layout"].to_i rescue 2
  debug "Barclamp #{bc} (format v#{bc_layout}) added to Crowbar Framework.  Review #{filelist} for files created."
end

def bc_install_layout_2_migrations(bc, bc_path, yaml)
  #database migration
  bc_layout = yaml["crowbar"]["layout"].to_i rescue 2
  if bc_layout > 1
    FileUtils.cd(@CROWBAR_PATH) do
      system "RAILS_ENV=production rake railties:install:migrations"
      debug "Engine migrations copied in" 
      db = system "RAILS_ENV=production rake db:migrate"
      debug "Database migration invoked - #{db}"
    end
  end
end

# upload the chef parts for a barclamp
def bc_install_layout_1_chef(bc, bc_path, yaml)
  unless File.exists? '/root/.chef/knife.rb'
    puts "Not uploading Barclamp #{bc} Chef Components as knife hasn't been not configured yet."
    return
  end

  log_path = File.join '/var', 'log', 'barclamps'
  FileUtils.mkdir log_path unless File.directory? log_path
  log = File.join log_path, "#{bc}.log"
  system "date >> #{log}"
  debug "Capturing chef install logs to #{log}"
  chef = File.join bc_path, 'chef'
  cookbooks = File.join chef, 'cookbooks'
  databags = File.join chef, 'data_bags'
  roles = File.join chef, 'roles'

  if File.exists? '/etc/SuSE-release'
    rpm = 'crowbar-barclamp-' + bc
    debug "on SUSE machine; obtaining chef components from #{rpm}"
    rpm_files = get_rpm_file_list(rpm)
    upload_cookbooks_from_rpm rpm, rpm_files, bc_path, log
    upload_data_bags_from_rpm rpm, rpm_files, bc_path, log
    upload_roles_from_rpm     rpm, rpm_files, bc_path, log
  else
    debug "obtaining chef components from " + bc_path
    upload_cookbooks_from_dir cookbooks, ['ALL'], bc_path, log
    upload_data_bags_from_dir databags, bc_path, log
    upload_roles_from_dir     roles,    bc_path, log
  end

  puts "Barclamp #{bc} (format v1) Chef Components Uploaded."
end

def get_rpm_file_list(rpm)
  cmd = "rpm -ql #{rpm}"
  file_list = IO.popen(cmd).readlines().map { |line| line.rstrip }
  raise cmd + " failed" unless $? == 0
  raise "got empty file list from #{cmd}" if file_list.empty?
  debug "obtained file list from #{rpm} rpm"
  return file_list
end

def upload_cookbooks_from_rpm(rpm, rpm_files, bc_path, log)
  cookbooks_dir = "#{@BASE_PATH}/chef/cookbooks"
  cookbooks = rpm_files.inject([]) do |acc, file|
    if File.directory?(file) and file =~ %r!^#{cookbooks_dir}/([^/]+)$!
      cookbook = File.basename(file)
      debug "will upload #{cookbook} from #{file} from #{rpm} rpm"
      acc.push cookbook
    end
    acc
  end
  if cookbooks.empty?
    puts "WARNING: didn't find any cookbooks from #{rpm} rpm in #{cookbooks_dir}"
  else
    upload_cookbooks_from_dir(cookbooks_dir, cookbooks, bc_path, log)
  end
end

def upload_data_bags_from_rpm(rpm, rpm_files, bc_path, log)
  data_bags_dir = "#{@BASE_PATH}/chef/data_bags"
  data_bag_files = rpm_files.grep(%r!^#{data_bags_dir}/([^/]+)/[^/]+\.json$!) do |path|
    [ $1, path ]
  end
  if data_bag_files.empty?
    puts "WARNING: didn't find any data bags from #{rpm} rpm in #{data_bags_dir}"
  else
    data_bag_files.each do |bag, bag_item_path|
      debug "uploading #{bag} from #{rpm} rpm"
      upload_data_bag_from_file(bag, bag_item_path, bc_path, log)
    end
  end
end


def upload_roles_from_rpm(rpm, rpm_files, bc_path, log)
  roles_dir = "#{@BASE_PATH}/chef/roles"
  roles = rpm_files.grep(%r!^#{roles_dir}/([^/]+)$!)
  if roles.empty?
    puts "WARNING: didn't find any roles from #{rpm} rpm in #{roles_dir}"
  else
    roles.each do |role|
      upload_role_from_dir(role, bc_path, log)
    end
  end
end

def upload_cookbooks_from_dir(cookbooks_dir, cookbooks, bc_path, log)
  upload_all = cookbooks.length == 1 && cookbooks[0] == 'ALL'
  if File.directory? cookbooks_dir
    FileUtils.cd cookbooks_dir
    opts = upload_all ? '-a' : cookbooks.join(' ')
    knife_cookbook = "knife cookbook upload -o . #{opts} -V -k /etc/chef/webui.pem -u chef-webui"
    debug "running #{knife_cookbook} from #{cookbooks_dir}"
    unless system knife_cookbook + " >> #{log} 2>&1"
      fatal "#{bc_path} #{knife_cookbook} upload failed.", log
    end
    debug "\texecuted: #{bc_path} #{knife_cookbook}"
  else
    debug "\tNOTE: could not find cookbooks dir #{cookbooks_dir}"
  end
end

def upload_data_bags_from_dir(databags_dir, bc_path, log)
  if File.exists? databags_dir
    Dir.entries(databags_dir).each do |bag|
      next if bag == "." or bag == ".."
      bag_path = File.join databags_dir, bag
      FileUtils.chmod 0755, bag_path
      chmod_dir 0644, bag_path
      upload_data_bag_from_dir bag, bag_path, bc_path, log
    end
  else
    debug "\tNOTE: could not find data bags dir #{databags_dir}"
  end
end

# Upload data bag items from any JSON files in the provided directory
def upload_data_bag_from_dir(bag, bag_path, bc_path, log)
  json = Dir.glob(bag_path + '/*.json')
  json.each do |bag_item_path|
    upload_data_bag_from_file(bag, bag_item_path, bc_path, log)
  end
end

def create_data_bag(bag, log, bc_path)
  knife_bag  = "knife data bag create #{bag} -V -k /etc/chef/webui.pem -u chef-webui"
  unless system knife_bag + " >> #{log} 2>&1"
    fatal "#{knife_bag} failed.", log
  end
  debug "\texecuted: #{bc_path} #{knife_bag}"
end

def upload_data_bag_from_file(bag, bag_item_path, bc_path, log)
  create_data_bag(bag, log, bc_path)

  knife_databag  = "knife data bag from file #{bag} #{bag_item_path} -V -k /etc/chef/webui.pem -u chef-webui"
  unless system knife_databag + " >> #{log} 2>&1"
    fatal "#{knife_databag} failed.", log
  end
  debug "\texecuted: #{bc_path} #{knife_databag}"
end

def upload_roles_from_dir(roles, bc_path, log)
  if File.directory? roles
    FileUtils.cd roles
    Dir[roles + "/*.rb"].each do |role_path|
      upload_role_from_dir(role_path, bc_path, log)
    end
  else
    debug "\tNOTE: could not find roles dir #{roles}"
  end
end

def upload_role_from_dir(role_path, bc_path, log)
  debug "will upload #{role_path}"
  knife_role = "knife role from file #{role_path} -V -k /etc/chef/webui.pem -u chef-webui"
  unless system knife_role + " >> #{log} 2>&1"
    fatal "#{knife_role} failed.", log
  end
  debug "\texecuted: #{bc_path} #{knife_role}"
end

def bc_install_layout_1_cache(bc, bc_path)
  return unless File.directory?(File.join(bc_path,"cache"))
  Dir.entries(File.join(bc_path,"cache")).each do |ent|
    debug ent.inspect
    case
    when ent == "files"
      debug "Copying files"
      system "cp -r \"#{bc_path}/cache/#{ent}\" /tftpboot"
    when ent == "gems"
      # Symlink the gems into One Flat Directory.
      debug "Installing gems"
      Dir.entries("#{bc_path}/cache/gems").each do |gem|
        next unless /\.gem$/ =~ gem
        unless File.directory? "/tftpboot/gemsite/gems"
          system "mkdir -p /tftpboot/gemsite/gems"
        end
        unless File.symlink? "/tftpboot/gemsite/gems/#{gem}"
	  debug "Symlinking #{bc_path}/cache/gems/#{gem} into /tftpboot/gemsite/gems"
          File.symlink "#{bc_path}/cache/gems/#{gem}", "/tftpboot/gemsite/gems/#{gem}"
        end
      end
      debug "Done"
    when File.directory?("#{bc_path}/cache/#{ent}/pkgs")
      debug "Installing packages"
      # We have actual packages here.  They map into the target like so:
      # bc_path/ent/pkgs -> /tftboot/ent/crowbar-extras/bc
      unless File.directory? "/tftpboot/#{ent}/crowbar-extra/"
        system "mkdir -p \"/tftpboot/#{ent}/crowbar-extra/\""
      end
      # sigh, ubuntu-install and redhat-install.
      unless File.symlink? "/tftpboot/#{ent}/crowbar-extra/#{bc_path.split('/')[-1]}"
	debug "Symlinking #{bc_path}/cache/#{ent}/pkgs into /tftpboot/#{ent}/crowbar-extra"
        File.symlink "#{bc_path}/cache/#{ent}/pkgs", "/tftpboot/#{ent}/crowbar-extra/#{bc_path.split('/')[-1]}"
      end
    end
    debug "Done"
    true
  end
end
