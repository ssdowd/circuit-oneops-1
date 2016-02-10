# Copyright 2016, Walmart Stores, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fog'
require 'json'


def clean_for_log( log )
  return log.gsub("\n"," ").gsub("<","").gsub(">","")
end

cloud_name = node[:workorder][:cloud][:ciName]
token = node[:workorder][:services][:compute][cloud_name][:ciAttributes]
conn = Fog::Compute.new({
  :provider => 'AWS',
  :region => token[:region],
  :aws_access_key_id => token[:key],
  :aws_secret_access_key => token[:secret]
})

rfcCi = node[:workorder][:rfcCi]
Chef::Log.debug("rfcCi attrs:"+rfcCi[:ciAttributes].inspect.gsub("\n"," "))

security_domains = []
nsPathParts = rfcCi[:nsPath].split("/")
security_domain = nsPathParts[3]+'.'+nsPathParts[2]+'.'+nsPathParts[1]
security_domains << security_domain
Chef::Log.debug("security domain: "+ security_domain)

node.workorder.payLoad["DependsOn"].each do |dep|
  if dep["ciClassName"] =~ /Secgroup/
    security_domains << dep["ciAttributes"][:group_name]
    Chef::Log.debug("security domain add: "+ dep["ciAttributes"][:group_name])
  end
end

# size / flavor
sizemap = JSON.parse( token[:sizemap] )
size_id = sizemap[rfcCi[:ciAttributes][:size]]
Chef::Log.info("flavor: #{size_id}")

# image_id
image = conn.images.get node[:image_id]
Chef::Log.info("image: "+clean_for_log(image.inspect) )

server = nil

if ! rfcCi["ciAttributes"]["instance_id"].nil? && 
   ! rfcCi["ciAttributes"]["instance_id"].empty? &&
   ! rfcCi["rfcAction"] == "replace"
     
  server = conn.servers.get(rfcCi["ciAttributes"]["instance_id"])
 
else
  conn.servers.all.each do |s|

   tags = s.tags
   Chef::Log.debug("tags: "+tags.inspect)

   if tags.has_key?("Name") && tags["Name"] == node.server_name  && (s.state == "running" || s.state == "stopped")
     s.reload
     server = s
     break
   end

  end

end


# security group per env
done = false
retry_count = 0
max_retry_count = 10
while !done && retry_count < max_retry_count do
  retry_count += 1
  Chef::Log.info("sg: #{security_domain}")
  sg = conn.security_groups.new(:name => security_domain, :description => "OneOps-generated environment-level security group")
  begin
    sg.save
    done = true
  rescue Exception => e
    if e.message =~ /already exists/
      Chef::Log.info("security group #{security_domain} already created.")
      done = true
    elsif e.message =~ /RequestLimitExceeded/
      wait_sec = retry_count * 30
      Chef::Log.info("RequestLimitExceeded...waiting #{wait_sec} sec")
      sleep wait_sec
    else
      Chef::Log.error(e.inspect)
      exit 1
    end
  end
end


done = false
retry_count = 0
while !done && retry_count < max_retry_count do
  retry_count += 1

  # add inductor ssh only rule
  begin
    # global port 22 open until sort out why security_group using another group not working     
    sg.authorize_port_range( 22..22, {} )
    done = true
  rescue Exception => e
      if e.message =~ /already (been authorized|exists)/
        Chef::Log.info("security group #{security_domain} already authorize_port_range 22.")
        done = true
      elsif e.message =~ /RequestLimitExceeded/
        wait_sec = retry_count * 30
        Chef::Log.info("RequestLimitExceeded...waiting #{wait_sec} sec")
        sleep wait_sec
      else
        Chef::Log.error(e.message)
        exit 1
      end
  end
end


done = false
retry_count = 0
while !done && retry_count < max_retry_count do
  retry_count += 1
  # allow all from env sg
  env_sg = conn.security_groups.get(security_domain)
  begin
    sg.authorize_port_range( 1..65535, {:group => { env_sg.owner_id => env_sg.group_id } } )
    sg.authorize_port_range( 1..65535, {:ip_protocol => "udp", :group => { env_sg.owner_id => env_sg.group_id } } )
  rescue Exception => e

    if e.message =~ /already (been authorized|exists)/
      Chef::Log.info("security group #{security_domain} already authorize_port_range for env")
      done = true
    elsif e.message =~ /RequestLimitExceeded/
      wait_sec = retry_count * 30
      Chef::Log.info("RequestLimitExceeded...waiting #{wait_sec} sec")
      sleep wait_sec
    else
      Chef::Log.error(e.message)
      exit 1
    end

  end
end


if server.nil?
  Chef::Log.info("creating server")

  compute_service = node[:workorder][:services][:compute][cloud_name][:ciAttributes]
  if compute_service.has_key?("availability_zones") && !compute_service[:availability_zones].empty?
    availability_zones = JSON.parse(compute_service[:availability_zones])
  end
  
  if availability_zones.size > 0
    case node.workorder.box.ciAttributes.availability
    when "redundant"
      instance_index = node.workorder.rfcCi.ciName.split("-").last.to_i + node.workorder.box.ciId
      index = instance_index % availability_zones.size
      availability_zone = availability_zones[index]
    else
      random_index = rand(availability_zones.size)
      availability_zone = availability_zones[random_index]
    end
  end

  manifest_ci = node.workorder.payLoad.RealizedAs[0]
  
  if manifest_ci["ciAttributes"].has_key?("required_availability_zone") &&
    !manifest_ci["ciAttributes"]["required_availability_zone"].empty?
    
    availability_zone = manifest_ci["ciAttributes"]["required_availability_zone"]
    Chef::Log.info("using required_availability_zone: #{availability_zone}")
  end
 
  puts "***RESULT:availability_zone=#{availability_zone}"
       
  # needed for centos to see ephemerals
  block_device_mapping = [
    { 'DeviceName' => '/dev/sdf', 'VirtualName' => 'ephemeral0' },
    { 'DeviceName' => '/dev/sdg', 'VirtualName' => 'ephemeral1' }
  ]

  done = false
  retry_count = 0
  while !done && retry_count < max_retry_count do
    retry_count += 1

    begin
      server = conn.servers.create(
                 :image_id => image.id,
                 :flavor_id => size_id,
                 :key_name => node.kp_name,
                 :groups => security_domains,
                 :availability_zone => availability_zone,
                 :block_device_mapping => block_device_mapping,
                 :tags => {:Name => node.server_name }
               )
      done = true      
    rescue Exception => e
      case e.message
      when /not supported in your requested Availability Zone/
        compute_service = node[:workorder][:services][:compute][cloud_name][:ciAttributes]
        if compute_service.has_key?("availability_zones") && !compute_service[:availability_zones].empty?
          availability_zones = JSON.parse(compute_service[:availability_zones])
        end

        availability_zone = availability_zones[rand(availability_zones.size-1)]
        
        Chef::Log.info("hit: not supported in your requested Availability Zone, trying new az: #{availability_zone}")
        puts "***RESULT:availability_zone=#{availability_zone}"
        retry
                
      when /RequestLimitExceeded/
        wait_sec = retry_count * 30
        Chef::Log.info("RequestLimitExceeded...waiting #{wait_sec} sec")
        sleep wait_sec
      else
        Chef::Log.error(e.message)
        exit 1
      end

    end
  end

  server.wait_for { ready? }
  Chef::Log.info("server ready: "+clean_for_log(server.inspect) )
  node.set[:ip] = server.public_ip_address || server.private_ip_address
  include_recipe "compute::ssh_port_wait"

else

  if server.state == "stopped"
    Chef::Log.info("starting server")
    server.start
    server.wait_for { ready? }
  end

  a = server
  server = nil
  server = conn.servers.get(a.id)
  node.set[:ip] = server.public_ip_address || server.private_ip_address  
  Chef::Log.info("running server: "+clean_for_log(server.inspect) )

end

if node.ostype =~ /centos/ &&
  node.set["use_initial_user"] = true
  node.set["initial_user"] = "ec2-user"
end

puts "***RESULT:private_ip="+server.private_ip_address
puts "***RESULT:private_dns="+server.private_dns_name
puts "***RESULT:public_ip="+server.public_ip_address
puts "***RESULT:public_dns="+server.dns_name
puts "***RESULT:dns_record="+server.dns_name
puts "***RESULT:instance_id="+server.id
