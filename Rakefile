require 'rubygems'
require 'rubygems/package_task'

spec = Gem::Specification.new do |s|
 s.name = "redact"
 s.version = "0.1.1"
 s.date = Time.now
 s.email = "wmorgan-redact@masanjin.net"
 s.authors = ["William Morgan"]
 s.summary  = "A dependency-based work planner for Redis."
 s.description = <<EOS
Redact is a dependency-based work planner for Redis. It allows you to express
your work as a set of tasks that are dependent on other tasks, and to execute
runs across this graph, in such a way that all dependencies for a task are
guaranteed to be satisfied before the task itself is executed.
EOS
 s.homepage = "http://gitub.com/wmorgan/redact"
 s.files = %w(README COPYING lib/redact.rb bin/redact-monitor views/index.erb)
 s.executables = []
 s.rdoc_options = %w(-c utf8 --main README)
 s.licenses = "COPYING"
 s.add_runtime_dependency 'trollop', '~> 2.0'
 s.add_runtime_dependency 'sinatra', '~> 1.4.5'
end

task :rdoc do |t|
  sh "rm -rf doc; rdoc #{spec.rdoc_options.join(' ')} #{spec.files.join(' ')}"
end

task :test do |t|
  sh "ruby -Ilib test/redact.rb"
end

Gem::PackageTask.new spec do
end
