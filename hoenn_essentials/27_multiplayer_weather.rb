# Weather belongs to Hoenn Essentials, independently of the other two mods.
# The lobby host owns fronts for every visited map, including maps guests visit
# alone. Guests temporarily display the host's forecast without saving it over
# their own weather. KIF authenticates the sender and checks the JSON envelope.
if defined?(KIF::Net::ModShare)
module HoennWeatherMultiplayer
  ID=:hoenn_essentials_weather
  VERSION=1
  @session=nil; @cache={}; @queue=[]; @last_send=-10; @revision=0
  def self.guest?; KIF::Net.connected? && !KIF::Net.host?; end
  def self.now; KIF::Net.now; end
  def self.session_changed
    session=KIF::Net.connected? ? KIF::Net.session : nil
    return if @session.equal?(session) && @global.equal?($PokemonGlobal)
    restore
    @session=session; @global=$PokemonGlobal
    @queue=[]; @cache={}; @revision=0; @accepted={}; @last_send=-10
    @generation=session ? KIF::Net::Crypto.random(6).unpack1('H*') : nil
    @host_generation=nil
    if guest?
      HoennWeatherKIF.load_saved_state
      $game_weather ||= GameWeather.new
      @backup=($game_weather.current_weather || {}).each_with_object({}) { |(k,v),h| h[k]=v.dup }
    end
  end
  def self.restore
    $game_weather.current_weather=@backup if @backup && $game_weather
    @backup=nil
    HoennWeatherKIF.instance_variable_set(:@last_display,nil)
  end
  def self.weather_id(text)
    return nil unless text.is_a?(String)
    data=GameData::Weather::DATA.values.find { |v| v.id.to_s==text }
    data && data.id
  end
  def self.receive(_name,key,d,from=nil)
    session_changed
    s=@session
    return unless s && d.is_a?(Hash) && d['v']==VERSION
    sender=from || (s.peers.first && s.peers.first[0])
    return unless s.peers.any? { |row| row[0]==sender }
    if key=='ask' && s.role==:host
      map=d['m']
      return unless map.is_a?(Integer) && map.between?(1,100_000) && GameData::MapMetadata.try_get(map)
      return unless HoennWeatherKIF.outdoors?(map)
      $game_weather ||= GameWeather.new
      $game_weather.current_weather ||= {}
      $game_weather.current_weather[map] ||= HoennWeatherKIF.pick(map)
      broadcast([map],sender)
    elsif key=='fronts' && sender==0 && guest?
      rows=d['rows']; gen=d['g']; rev=d['r']
      return unless gen.is_a?(String) && gen.match?(/\A[0-9a-f]{12}\z/) &&
        rev.is_a?(Integer) && rev.between?(0,2**53) && rows.is_a?(Array) && rows.length<=40
      checked=rows.map do |row|
        return unless row.is_a?(Array) && row.length==3 && row[0].is_a?(Integer) &&
          row[0].between?(1,100_000) && row[2].is_a?(Integer) && row[2].between?(0,10)
        type=weather_id(row[1]); return unless type
        [row[0],type,row[2]]
      end
      if @host_generation!=gen
        @cache={}; @accepted={}; @host_generation=gen
      end
      checked.each do |map,type,intensity|
        next if (@accepted[map] || -1)>rev
        @accepted[map]=rev; @cache[map]=[type,intensity]
      end
      display
    end
  end
  def self.broadcast(ids=nil,to=nil)
    return unless $game_weather && $game_weather.current_weather
    rows=$game_weather.current_weather.filter_map do |map,w|
      next if ids && !ids.include?(map)
      next unless map.is_a?(Integer) && map.between?(1,100_000) &&
        w.is_a?(Array) && weather_id(w[0].to_s)
      [map,w[0].to_s,w[1].to_i.clamp(0,10)]
    end
    @revision+=1
    rows.each_slice(40) do |slice|
      @queue << ['fronts',{'v'=>VERSION,'g'=>@generation,'r'=>@revision,'rows'=>slice},to] if @queue.length<64
    end
  end
  def self.display
    return unless guest? && $game_map && $game_screen && $game_weather
    $game_weather.current_weather ||= {}
    @cache.each { |map,w| $game_weather.current_weather[map]=w.dup }
    map=$game_map.map_id
    w=HoennWeatherKIF.outdoors?(map) ? (@cache[map] || [:None,0]) : [:None,0]
    $game_screen.weather(w[0],w[1],20) if $game_screen.weather_type!=w[0] || $game_screen.weather_power!=w[1]
    HoennWeatherKIF.update_fog_overlay
  end
  def self.frame
    session_changed
    return unless @session && $game_map
    if now-@last_send>=2
      if guest?
        @queue << ['ask',{'v'=>VERSION,'m'=>$game_map.map_id},0] if @queue.length<64
      else
        broadcast
      end
      @last_send=now
    end
    4.times do
      item=@queue.first; break unless item
      key,data,to=item
      peers=KIF::Net.peers_with(ID)
      have=@session.peers.length<=1 ? KIF::Net.partner_has?(ID) : (to ? peers.include?(to) : !peers.empty?)
      unless have
        # Another player may still be announcing its mods. Retry next frame.
        break
      end
      target=@session.peers.length<=1 ? nil : to
      break unless KIF::Net.share(ID,key,data,to:target)
      @queue.shift
    end
    display if guest?
  end
  def self.with_local_weather
    remote=$game_weather.current_weather if guest? && @backup && $game_weather
    $game_weather.current_weather=@backup if remote
    yield
  ensure
    $game_weather.current_weather=remote if remote && $game_weather
  end
end
KIF::Net.on_share(HoennWeatherMultiplayer::ID) { |name,key,data,from=nil| HoennWeatherMultiplayer.receive(name,key,data,from) }
HoennWeatherKIF.singleton_class.prepend(Module.new do
  def tick(force=false)
    HoennWeatherMultiplayer.session_changed
    if HoennWeatherMultiplayer.guest?
      HoennWeatherMultiplayer.frame
    else
      super
      HoennWeatherMultiplayer.frame
    end
  end
  def persist_state
    return if HoennWeatherMultiplayer.guest?
    super
  end
end)
Game.singleton_class.prepend(Module.new do
  def save(*args,**kwargs,&block)
    HoennWeatherMultiplayer.with_local_weather { super }
  end
end)
end
