module Couchbase
    module Component
        class ClusterCredentials
            attr_accessor :username, :password, :port
            def initialize(username, password, port)
                @username=username
                @password=password
                @port=port
            end
        end
        class BucketComponent

            @data
            @cluster
            @name
            @replica
            @password
            @memory

            def initialize(data)

                @data = data

                attributes = data["bucket"]
                ip = "localhost"

                @name = attributes["bucketname"]
                @replica = attributes["bucketreplica"]
                @password = attributes["bucketpassword"]
                @memory = attributes["bucketmemory"]
                cluster_credentials = credentials

                @cluster = Couchbase::CouchbaseCluster.new(ip, cluster_credentials.username, cluster_credentials.password)

                validate_all_active_healthy

            end

            def credentials
                cluster_credentials = nil
                @availability_mode = @data.workorder.box.ciAttributes.availability
                if @availability_mode == 'single'
                    cb = @data.workorder.payLoad.DependsOn.select { |cm| cm['ciClassName'].split('.').last == 'Couchbase'}.first
                    cba = cb[:ciAttributes]
                    user = cba['adminuser']
                    pass = cba['adminpassword']
                    port = cba['port']
                    cluster_credentials = ClusterCredentials.new(user, pass, port)
                else
                  # dynamic payload defined in the pack to get the resources -
                  # this seems to be in the RealizedAttrs...
                    realizedAttrs = @data.workorder.payLoad[:RealizedAs][0].ciAttributes
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
                    cluster_credentials = ClusterCredentials.new(user, pass, port)
                end
              cluster_credentials
            end
            def add
                begin
                    @cluster.add_bucket(@name, @password, @memory, @replica)
                rescue Exception => e
                    puts e.message
                    if e.message.include?("Bucket with given name already exists")
                        update
                    else
                      raise e
                    end

                end

            end

            def update
                validate
                @cluster.edit_bucket(@name, @password, @memory, @replica)
            end

            def delete
                if @cluster.list_buckets.include?(@name)
                    @cluster.remove_bucket(@name, @password)
                end
            end

            def validate_all_active_healthy

                if !@cluster.all_active?
                    raise "One or more nodes in the cluster are not active members." +
                              " SEE: https://confluence.walmart.com/x/qI6-Bw"
                end

                if !@cluster.all_healthy?
                    raise "One or more nodes in the cluster are not healthy." +
                              " SEE: https://confluence.walmart.com/x/qI6-Bw"
                end

            end

            def validate

                buckets = @cluster.list_buckets

                if !buckets.include?(@name)
                    raise "Bucket #{@name} is not part of the cluster." +
                              " SEE: https://confluence.walmart.com/x/qI6-Bw"
                end



                if @cluster.rebalance?
                    raise "Rebalance in progress." +
                              " SEE: https://confluence.walmart.com/x/qI6-Bw"
                end

            end

        end

    end
end
