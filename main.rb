require 'open3'

###### Enviroment Variable Check
def env_has_key(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

xcode_list_dir = env_has_key("AC_XCODE_LIST_DIR")
xcode_version = env_has_key("AC_XCODE_VERSION") || abort('Missing AC_XCODE_VERSION.')
xcode_developer_dir_path = "#{xcode_list_dir}/#{xcode_version}/Xcode.app/Contents/Developer"

if !Dir.exist?('/Applications/Xcode/')
    path_version = xcode_version.split(".")[0...-1].join(".")
    xcode_developer_dir_path = "/Volumes/Xcode.#{path_version}/Xcode.app/Contents/Developer"
end

def run_command(command)
    puts "@@[command] #{command}"
    status = nil
    stdout_str = nil
    stderr_str = nil
    Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
      stdout.each_line do |line|
        puts line
      end
      stdout_str = stdout.read
      stderr_str = stderr.read
      status = wait_thr.value
    end
  
    unless status.success?
      raise stderr_str
    end
end


run_command("sudo xcode-select --switch \"#{xcode_developer_dir_path}\"")

puts "\n"
run_command("xcodebuild -version")
puts "\n"

### Write Environment Variable
open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
  f.puts "XCODE_DEVELOPER_DIR_PATH=#{xcode_developer_dir_path}"
}

exit 0