#Require rubygems for old (pre 1.9 versions of Ruby and Debian-based systems)
require 'rubygems'
require 'client_world_connection.rb'
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

def getOwlTime()
  t = Time.now
  return t.tv_sec * 1000 + t.usec/10**3
end

if (ARGV.length != 4)
  puts "This program requires the following arguments:"
  puts "\t<world model ip> <client port> <solver port> <threshold>"
  exit
end
@wmip       = ARGV[0]
@solver_port = ARGV[1]
@client_port = ARGV[2]
@threshold  = ARGV[3].to_i

@transmitter_to_name = {}
lock = Mutex.new

#The third argument is the origin name, which should be your solver or
#client's name
wm = SolverWorldModel.new(@wmip, @solver_port, 'proximity solver')

#Known rss values
@rss_vals = {}
#Current proximity values
@proximity = {}

#Connect to the world model as a client
cwm = ClientWorldConnection.new(@wmip, @client_port)
#Get anything with an attached sensor and remember the object names
sensor_request = cwm.streamRequest(".*", ['sensor.*'], 1000)
#Get median rss values of links
rss_request = cwm.streamRequest(".*", ['link median'], 1000)
while (cwm.connected and not sensor_request.isComplete() and not rss_request.isComplete() and not @quitting)
  if (sensor_request.hasNext)
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
  elsif (rss_request.hasNext)
    ids_to_check = {}
    result = rss_request.next()
    result.each_pair {|uri, attributes|
      ids = uri.split(".")
      txid = ids[1].to_i
      rxid = ids[2].to_i
      if (not @rss_vals.has_key? txid)
        @rss_vals[txid] = {}
      end
      @rss_vals[txid][rxid] = attributes[0].data.unpack('G')[0]
      ids_to_check[txid] = true
    }
    #Check modified transmitters for new proximity results and send new
    #solutions to the world model.
    new_solutions = []
    ids_to_check.each{|id, val|
      #Lock a mutex here for the @transmitter_to_key map
      lock.synchronize {
        if (@transmitter_to_name.has_key? id)
          name = @transmitter_to_name[id]
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
            attrib = WMAttribute.new('proximity', [0].pack('C') + packuint128(@proximity[id][0]), getOwlTime)
            #Making a solution with the name of the object that the sensor is attached to
            new_data = WMData.new(name, [attrib])
            new_solutions.push(new_data)
          end
        end
      }
    }
    if (not new_solutions.empty?)
      #Push the data, do not make new objects in the world model
      wm.pushData(new_solutions, false)
    end
  else
    sleep 1
  end
end

exit
