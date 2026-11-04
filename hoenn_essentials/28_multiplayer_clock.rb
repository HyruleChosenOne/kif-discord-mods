# Temporary host civil time for all time-of-day queries (lighting/encounters).
# Never changes Windows time or the guest's saved UnrealTime frame counters.
if defined?(KIF::Net::ModShare)
module HoennEssentialsClock
  ID=:hoenn_essentials_clock
  @session=nil; @sample=nil; @last_send=-10; @serial=0; @local_only=0
  def self.now; KIF::Net.now; end
  def self.refresh_tone
    PBDayNight.sheduleToneRefresh if PBDayNight.respond_to?(:sheduleToneRefresh)
  end
  def self.session_changed
    s=KIF::Net.connected? ? KIF::Net.session : nil
    return if @session.equal?(s) && @global.equal?($PokemonGlobal)
    @session=s; @global=$PokemonGlobal; @sample=nil; @previous=nil
    @last_send=-10; @serial=0; @received_serial=0
    @nonce=s ? KIF::Net::Crypto.random(6).unpack1('H*') : nil
    @host_nonce=nil
    refresh_tone
  end
  def self.civil(time)
    Time.utc(time.year,time.month,time.day,time.hour,time.min,time.sec+time.subsec).to_f
  end
  def self.receive(_name,key,data,from=nil)
    session_changed
    return unless @session && @session.role!=:host && key=='clock' && data.is_a?(Hash) && data['v']==1
    sender=from || (@session.peers.first && @session.peers.first[0])
    return unless sender==0 && @session.peers.any? { |p| p[0]==0 }
    epoch=data['e']; serial=data['n']; value=data['t']; rate=data['r']
    return unless epoch.is_a?(String) && epoch.match?(/\A[0-9a-f]{12}\z/) &&
      serial.is_a?(Integer) && serial.between?(1,2**53) &&
      value.is_a?(Numeric) && value.finite? && value.between?(-2_208_988_800,10_413_792_000) &&
      rate.is_a?(Numeric) && rate.finite? && rate.between?(0,3600)
    return if epoch==@host_nonce && serial<=@received_serial
    @host_nonce=epoch; @received_serial=serial
    @sample=[value.to_f,rate.to_f,now]
    refresh_tone
  end
  def self.current_time
    session_changed
    return nil unless @session && @session.role!=:host && @sample && @local_only==0
    seconds,rate,received=@sample
    # Interpolate between host samples; hold after a connection stalls so
    # paused or disconnected hosts cannot leave a runaway guest clock.
    Time.at(seconds+(now-received).clamp(0,2)*rate).utc
  end
  def self.frame
    session_changed
    return unless @session && @session.role==:host && $PokemonGlobal && now-@last_send>=0.5
    value=civil(pbGetTimeNow)
    rate=0.0
    if @previous && now>@previous[1]
      delta=(value-@previous[0])/(now-@previous[1])
      rate=delta if delta.between?(0,3600)
    end
    @previous=[value,now]
    data={'v'=>1,'e'=>@nonce,'n'=>@serial+1,'t'=>value,'r'=>rate}
    if KIF::Net.share(ID,'clock',data)
      @serial+=1; @last_send=now
    end
  rescue StandardError => e
    KIF::Net.log("Hoenn Essentials clock: #{e.class}: #{e.message}")
  end
  def self.with_local_clock
    @local_only+=1
    yield
  ensure
    @local_only-=1
  end
end
KIF::Net.on_share(HoennEssentialsClock::ID,host_only:true) do |name,key,data,from=nil|
  HoennEssentialsClock.receive(name,key,data,from)
end
Object.prepend(Module.new do
  def pbGetTimeNow
    # Run native bookkeeping too (extra seconds/days), then expose host time.
    local=super
    HoennEssentialsClock.current_time || local
  end
  private :pbGetTimeNow
end)
Graphics.singleton_class.prepend(Module.new do
  def update(*args)
    super
    HoennEssentialsClock.frame
  end
end)
Game.singleton_class.prepend(Module.new do
  def save(*args,**kwargs,&block)
    HoennEssentialsClock.with_local_clock { super }
  end
end)
end
