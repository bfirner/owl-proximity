#Require rubygems for old (pre 1.9 versions of Ruby and Debian-based systems)
require 'rubygems'
require 'client_world_connection.rb'
require 'solver_aggregator.rb'
require 'solver_world_model.rb'
require 'wm_data.rb'
require 'buffer_manip.rb'

@quitting = false
Signal.trap("SIGTERM") {
  puts "Exiting..."
  #Exit immediately if this is signalled twice
  exit if @quitting
  @quitting = true
}

Signal.trap("SIGINT") {
  puts "Exiting..."
  #Exit immediately if this is signalled twice
  exit if @quitting
  @quitting = true
}

if (ARGV.length != 6)
  puts "This program requires the following arguments:"
  puts "\t<aggregator ip> <aggregator port> <world model ip> <client port> <solver port> <threshold>"
  exit
end
@agg_ip     = ARGV[0]
@agg_port   = ARGV[1]
@wmip       = ARGV[2]
@solver_port = ARGV[3]
@client_port = ARGV[4]
@threshold  = ARGV[5].to_i

@transmitter_to_name = {}
lock = Mutex.new

#The third argument is the origin name, which should be your solver or
#client's name
@wm = SolverWorldModel.new(@wmip, @solver_port, 'proximity solver')

#TODO Would it be more appropriate to use results from the fingerprint solver here?
#TODO Should probably use mean or median RSS rather than the raw RSS values
#Start the RSS monitoring thread
@rss_thread = Thread.new do
  #Known rss values
  @rss_vals = {}
  #Current proximity values
  @proximity = {}
  sq = SolverAggregator.new(@agg_ip, @agg_port)
  while (not @quitting)

    #Request packets from any phy, don't specify a transmitter ID or
    #mask, and request packets every two seconds
    sq.sendSubscription([AggrRule.new(0, [], 2000)])
    while (sq.handleMessage and not @quitting) do
      if (sq.available_packets.length != 0) then
        ids_to_check = {}
        for packet in sq.available_packets do
          puts "Got packet #{packet}"
          if (not @rss_vals.has_key? packet.device_id)
            @rss_vals[packet.device_id] = {}
          end
          @rss_vals[packet.device_id][packet.receiver_id] = packet.rssi
          ids_to_check[packet.device_id] = true
        end
        sq.available_packets.clear
        #Check modified transmitters for new proximity results and send new
        #solutions to the world model.
        new_solutions = []
        ids_to_check.each{|id, val|
          puts "Checking id #{id}"
          #Lock a mutex here for the @transmitter_to_key map
          lock.synchronize {
            puts "Checking for name"
            if (@transmitter_to_name.has_key? id)
              name = @tramsmitter_to_name[id]
              puts "Checking id #{id} with name #{name}"
              #Check for a change in proximity
              changed = false
              #Insert the null ID if nothing is close and this is the first test
              if (not @proximity.has_key? id)
                changed = true
                @proximity[id] = 0, -200
              end
              cur_closest, cur_max = @proximity[id]
              #Go through the @rss_vals map to see if any rss values are above the threshold
              @rss_vals[id].each{|rxer, rss|
                #Change the proximity and set changed to true if a new proximite sensor is found
                if (rss > @threshold and rss > cur_max)
                  if (rxer == cur_closest)
                    #Update the rss level, but don't send a new solution
                    @proximity[id] = rxer, rss
                    cur_max = rss
                  else
                    @proximity[id] = rxer, rss
                    cur_max = rss
                    cur_closest = rxer
                    changed = true
                  end
                elsif (rss < @threshold and rxer == cur_closest)
                  #Just moved out of proximity
                  #TODO Might still be within proximity of another receiver
                  @proximity[id] = 0, -200
                  changed = true
                end
              }
              #Make a new solution if proximity has changed
              if (changed)
                if (@proximity[id][0] == 0)
                  puts "#{name} is not in proximity of any receiver."
                else
                  puts "#{name} is in close proximity to #{@proximity[id][0]}."
                end
                #Make an attribute for proximity with the closest receiver and the current time
                #TODO FIXME For now just inserting 0 as the phy
                attrib = WMAttribute.new('proximity', [0].pack('C') + packuint128(@proximity[id][0]), t.tv_sec * 1000 + t.usec/10**3)
                #Making a solution with the name of the object that the sensor is attached to
                new_data = WMData.new(name, [attrib])
                new_solutions.push(new_data)
              end
            end
          }
          puts "Done checking"
        }
        if (not new_solutions.empty?)
          #Push the data, do not make new objects in the world model
          wm.pushData(new_solutions, false)
        end
      end
    end
    #Finished with the aggregator
  end
  sq.close()
end


client_thread = Thread.new {
  #Connect to the world model as a client
  cwm = ClientWorldConnection.new(@wmip, @client_port)
  #Get anything with an attached sensor and remember the object names
  sensor_request = cwm.streamRequest(".*", ['sensor.*'], 1000)
  while (cwm.connected and not sensor_request.isComplete() and not @quitting)
    result = sensor_request.next()
    result.each_pair {|uri, attributes|
      #TODO FIXME Check for expirations
      attributes.each {|attr|
        puts "Mapping #{unpackuint128(attr.data[1,attr.data.length-1])} to #{uri}"
        #Lock a mutex here since this is accessed in the thread as well
        lock.synchronize {
          @transmitter_to_name[unpackuint128(attr.data[1,attr.data.length-1])] = uri
        }
      }
    }
  end
}

until @quitting do sleep 5 end

exit
