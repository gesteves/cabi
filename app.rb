require 'sinatra'
require 'json'
require 'httparty'
require 'dotenv'
require 'uri'
require 'dalli'
require 'nokogiri'

configure do
  Dotenv.load
  $stdout.sync = true
  if ENV['MEMCACHEDCLOUD_SERVERS']
    $cache = Dalli::Client.new(ENV['MEMCACHEDCLOUD_SERVERS'].split(','), username: ENV['MEMCACHEDCLOUD_USERNAME'], password: ENV['MEMCACHEDCLOUD_PASSWORD'])
  end
end

get '/' do
  @page_title = '/cabi: Capital Bikeshare in slack'
  erb :index, layout: :application
end

get '/privacy' do
  @page_title = '/cabi privacy policy'
  erb :privacy, layout: :application
end

get '/support' do
  @page_title = '/cabi support'
  erb :support, layout: :application
end

get '/auth' do
  @page_title = 'Auth failed!'
  if !params[:code].nil?
    token = get_access_token(params[:code])
    if token['ok']
      @page_title = 'Success!'
      erb :success, layout: :application
    else
      erb :fail, layout: :application
    end
  else
    erb :fail, layout: :application
  end
end

post '/search' do
  if params[:token] == ENV['SLACK_VERIFICATION_TOKEN']
    query = params[:text].sub(/^\s*(in|for|at)\s+/, '').strip
    if query == '' || query == 'help'
      response = { text: 'Enter an address to get the closest Capital Bikeshare dock with bikes. For example, `/cabi near 1600 Pennsylvania Avenue NW, Washington, DC`', response_type: 'ephemeral' }.to_json
    else
      # response = $cache.get(parameterize(query))
      # if response.nil?
        response = search(query)
      #   $cache.set(parameterize(query), response, 60)
      # end
    end
    status 200
    headers 'Content-Type' => 'application/json'
    body response
  else
    status 401
    body 'Unauthorized'
  end
end

def search(location)
  gmaps_response = HTTParty.get("http://maps.googleapis.com/maps/api/geocode/json?address=#{URI::encode(location)}&sensor=false").body
  gmaps = JSON.parse(gmaps_response)

  response = if gmaps['status'] == 'OK'
    lat = gmaps['results'][0]['geometry']['location']['lat']
    long = gmaps['results'][0]['geometry']['location']['lng']

    doc = Nokogiri::XML(HTTParty.get('http://www.capitalbikeshare.com/data/stations/bikeStations.xml').body)

    # Sort stations by distance

    stations = doc.css('station').sort { |a,b| distance([lat, long], [a.at('lat').text.to_f, a.at('long').text.to_f]) <=> distance([lat, long], [b.at('lat').text.to_f, b.at('long').text.to_f]) }
    # Get the first one that has > 0 bikes
    station = stations.find { |s| s.at('nbBikes').text.to_i > 0 }

    build_response(lat, long, station)
  else
    { text: 'Sorry, I don’t understand that address.', response_type: 'ephemeral' }
  end
  response.to_json
end

def build_response(lat, long, station)
  name = station.at('name').text
  bikes = station.at('nbBikes').text
  docks = station.at('nbEmptyDocks').text
  station_lat = station.at('lat').text
  station_long = station.at('long').text
  last_updated = station.at('latestUpdateTime').text.to_i
  link = "https://maps.google.com?saddr=#{lat},#{long}&daddr=#{station_lat},#{station_long}&dirflg=w"

  attachments = []
  attachment = { fallback: "The nearest Capital Bikeshare station with bikes is #{name}: #{link}", color: '#ff300b', pretext: "This is the nearest Capital Bikeshare station with bikes:", title: name, title_link: link, image_url: map_image(station_lat, station_long) }
  fields = []
  fields << { title: 'Available Bikes', value: bikes, short: true }
  fields << { title: 'Available Docks', value: docks, short: true }
  attachment[:fields] = fields
  attachments << attachment

  { response_type: 'in_channel', attachments: attachments }
end

# Haversine distance formula from http://stackoverflow.com/a/12969617
def distance(loc1, loc2)
  rad_per_deg = Math::PI/180  # PI / 180
  rkm = 6371                  # Earth radius in kilometers
  rm = rkm * 1000             # Radius in meters

  dlat_rad = (loc2[0]-loc1[0]) * rad_per_deg  # Delta, converted to rad
  dlon_rad = (loc2[1]-loc1[1]) * rad_per_deg

  lat1_rad, lon1_rad = loc1.map {|i| i * rad_per_deg }
  lat2_rad, lon2_rad = loc2.map {|i| i * rad_per_deg }

  a = Math.sin(dlat_rad/2)**2 + Math.cos(lat1_rad) * Math.cos(lat2_rad) * Math.sin(dlon_rad/2)**2
  c = 2 * Math::atan2(Math::sqrt(a), Math::sqrt(1-a))

  rm * c # Delta in meters
end

def map_image(lat, long)
  "https://maps.googleapis.com/maps/api/staticmap?key=#{ENV['MAPS_API_KEY']}&size=400x200&markers=#{lat},#{long}&scale=2"
end

def parameterize(string)
  string.gsub(/[^a-z0-9]+/i, '-').downcase
end

def get_access_token(code)
  response = HTTParty.get("https://slack.com/api/oauth.access?code=#{code}&client_id=#{ENV['SLACK_CLIENT_ID']}&client_secret=#{ENV['SLACK_CLIENT_SECRET']}&redirect_uri=#{request.scheme}://#{request.host_with_port}/auth")
  JSON.parse(response.body)
end
