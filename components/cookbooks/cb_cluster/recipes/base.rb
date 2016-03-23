#
# Cookbook Name:: couchbase-cluster
# Recipe:: default
#
# Copyright 2015, Walmart
#
# All rights reserved - Do Not Redistribute
#
Chef::Log.info("base started")

user = ''
pass = ''
port = ''

@availability_mode = node.workorder.box.ciAttributes.availability
if @availability_mode == 'single'
  cb = node.workorder.payLoad.DependsOn.select { |cm| cm['ciClassName'].split('.').last == 'Couchbase'}.first
  cba = cb[:ciAttributes]
  user = cba['adminuser']
  pass = cba['adminpassword']
  port = cba['port']
else
  realizedAttrs = node.workorder.payLoad[:RealizedAs][0].ciAttributes
  if realizedAttrs.has_key?("adminuser")
    user = realizedAttrs["adminuser"]
  end
  if realizedAttrs.has_key?("adminuser")
    user = realizedAttrs["adminuser"]
  end
  if realizedAttrs.has_key?("adminpassword")
    pass = realizedAttrs["adminpassword"]
  end
  if realizedAttrs.has_key?("port")
    port = realizedAttrs["port"]
  end
end

node.set[:couchbase][:user] = user
node.set[:couchbase][:pass] = pass
node.set[:couchbase][:port] = port
