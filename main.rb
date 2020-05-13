require 'open3'

###### Enviroment Variable Check
def env_has_key(key)
  return (ENV[key] != nil && ENV[key] !="") ? ENV[key] : abort("Missing #{key}.")
end

xcode_list_dir = env_has_key("AC_XCODE_LIST_DIR")
xcode_version = env_has_key("AC_XCODE_VERSION")

def run_command(command)
    puts "@[command] #{command}"
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


run_command("sudo xcode-select --switch \"#{xcode_list_dir}/#{xcode_version}/Xcode.app/Contents/Developer\"")

exit 0



