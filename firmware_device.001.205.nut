/** 1-Wire Temperature Probe Reader for LinkOEM 1-Wire Master
 * Designed to run on electric imp001 microcontroller.
 * 
 * Author:  Rod Gau
 * Date: 11/7/2015
 * 
 * Pre-release dev version "001.205"
 * Branch 001: dynamic bus  polling version
 * 
 * Revision History
 * Build (xyz):not 
 * 003  Branched from 000.303 device/agent code. Major re-write.
 *      Automatic sensor discovery: Device IDs not required in firmware. Up to 64 simultaneous sensors.
 *      GroveStreams datalogging
 *      Physically add/remove sensors while firmware running.
 *      1-wire bus continously monitored for faulty devices and connections.
 *      Output data stream dynamically shrinks/expands to fit sensor population.
 *      Cloud data logging transaction fees minimized:  Posts batched. Suspicious readings not posted.
 * 009  Optimizations:
 *        -devices table structure improved (purely key/value pairs instead of arrays)
 *        -added health status to devices table
 *        -'data' table removed (redundant now)
 *      Grovestreams agent modified to support new devices table structure
 * 044  HTTP handler agent created. Entry points added:
 *        ?show=disconnected: returns comma-delimited list of disconnected devices
 *        ?show=all: returns comma-delimited list of all discovered devices
 * 083  HTTP handler additions: JSON body option added
 *      Improved http request handler by removing agent's devices global and moving device.on() 
 *      handler to be defined inline to the http request handler code blocks (see agent comments).
 * 096  Xively logging added
 * 112  bug fix: http handler error if api-key missing in header
 * 115  new HTTP handler: { "logger" : { "gs": "true" / "false" , "xively": "true" / "false" , "imp": "true" / "false" } )
 *        (Grovestreams logging true/false, Xively logging true/false, server.logging true/false)
 * 124  bug found: forgot to add check within Xively logging to only post data for active sensors.
 *        (fixed but not yet tested)
 *      Xively logging: extensive new code to handle variable Channel streams (not yet tested)
 *        -Agent dynamically recreates Xively.Channel and Xively.Feed objects each log post.
 * 131  appears to be working!
 * 166  Expanding http handler to change logging settings (work in progress)
 *      HTTP handler: move api-key expectation from header to body (not all apps support headers?)
 * 183  Temperature conversion required delay now tied to device resolution (lower resn=faster loop speed)
 *      Keen IO data logging added.
 *      Restructured device table (removed redundant id slot, renamed primary slots as their location names)
 * 205  functional code node
 * 
 * Functional Notes:
 * -Sensor list is *replaced* each enumeration period. So, sensors previously reporting as "not found"
 *  will no longer do so after the new enumeration (since they're no longer in the devices table).
 *  While this is fine where sensors are intentionally unplugged, when they unknowingly fail/malfunction
 *  this "alarm" may go unnoticed (one enumeration period only).
 *    Therefore:  need a better alarm mechanism.
 * -Expanding http handler to change logging settings (work in progress)
 * -HTTP handler: move api-key expectation from header to body (not all apps support headers?)
 **/

/*------ Tables ----------*/
devices <- {};	// table of 1-wire device IDs and temperature readings
// logger <- { "gs" :      { "logging" : "false", "period" : 3600 } ,
//             "xively" :  { "logging" : "false", "period" : 3600 } ,
//             "imp" :     { "logging" : "false" } };
// if ( logger.gs.logging == "true" ) 

/*------ Globals ---------*/
count_devNotFound <- 0;   // 'device not found' error count
count_polls <- 0;         // 1-wire bus temperature polling count
count_readings <- 0;      // sensor atempted readings count
count_enumerations <- 0;  // 1-wire bus device enumeration count
count_convertError <- 0;  // sensor conversion error count
convDelay <- 0.2;         // required sensor conversion time (sec)
startTime <- 0; // timekeeping

keen_logging <- true;
xively_logging <- false;
gs_logging <- false;
debug <- true; // imp server debug logging

const BUILD = "205";
const POLLING_PERIOD = 2; // how often 1-wire bus temperatures are read (seconds)
const DEVICE_REFRESH = 10000; // how often 1-wire bus checked for new sensor devices (milliseconds)
const GS_PERIOD = 60;     // time between Grovestreams uploads (seconds)
const XIVELY_PERIOD = 5;     // time between Xively uploads (seconds)
const KEEN_PERIOD = 30;     // time between KeenIO uploads (seconds)


/*----------------- initialize PIN parameters -------------------
*/
// alias pin5, pin7 as UART57 for 1-wire bus
onewire <- hardware.uart57;
onewire.configure(9600, 8, PARITY_NONE, 1, NO_CTSRTS);

// alias pin9 as digital output for led
led <- hardware.pin9;
led.configure( DIGITAL_OUT );
ledState <- 0;


function heartbeat()  // flash led heartbeat
{
	imp.wakeup( 0.5 , heartbeat );
	ledState = 1-ledState;
	led.write (ledState);
}

function ow_setRes(bits) // set temperature conversion resolution for all devices on bus
{                        // Higher resn takes the DS18B20 sensor longer, set conv. delay accordingly.
  local config;
  
  if (bits == 9)       { config="1F"; convDelay = 0.1; } // 0.5 °C    (94 ms)
  else if (bits == 10) { config="3F"; convDelay = 0.2; } // 0.25 °C   (188 ms)
  else if (bits == 11) { config="5F"; convDelay = 0.4; } // 0.125 °C  (375 ms)
  else if (bits == 12) { config="7F"; convDelay = 0.8; } // 0.0625 °C (750 ms)
  else
    { bits = 10; config="3F"; convDelay = 0.2; } // default to 0.25 °C
  foreach ( sensor in devices )
  {
    ow_reset();
    onewire.write("b55");
    onewire.write(sensor.revid);
    onewire.write(format("4E4B46%s",config)); // 0x4B, 0x46, config -> scratchpad
    ow_reset();
    onewire.write("b55");
    onewire.write(sensor.revid);
    onewire.write("48");  // write scratchpad -> EEPROM
    onewire.flush();
    imp.sleep (0.1);  // give EEPROM time to be written before next bus reset
    //if (debug) server.log(format("[1-wire bus]: %s resolution set to %d bits", sensor.revid, bits) );
  }
}

function ow_purge()  // purge uart receive buffer of any 1-wire bus chatter
{
  local b = onewire.read();
  while(b != -1)
    b = onewire.read();
}

function ow_reset() // reset 1-wire bus
{
  onewire.write(13);  // ensures we're not in byte command mode
  onewire.write("r"); // reset bus
  onewire.flush();
}

function ow_convertall() // issue convert command to all sensor devices on 1-wire network
{
  onewire.write(13);
  onewire.write("bCC44"); // Skip ROM-addressing mode. All devices convert. 
  onewire.write(13);
  onewire.flush();
}

function ow_readall() // Repeatedly read temperature of all devices on 1-wire network.
{											// Output: table updated with temperature results
                      // Requires: global 'device' table to hold output
// function runs every POLLING_PERIOD seconds
	imp.wakeup ( POLLING_PERIOD, ow_readall );
	
	local now = hardware.millis();
	if ( now-startTime >= DEVICE_REFRESH ) // refresh 1-wire bus device list, periodically
	{
	  server.log("refreshing device list");
		devices = ow_enum();
	  ow_setRes(0); // ensures any new sensors also set to default resolution
		startTime = hardware.millis(); // reset refresh counter
	}

  if ( devices.len() >0 )
  {  /*-------- read all sensors ---------*/
  
    // issue convert command to all devices
    ++count_polls;
    if (debug) server.log("Polling " + devices.len() + " sensors:");
    ow_reset();
    ow_convertall();
    imp.sleep(convDelay); // wait for conversions to complete per DS18B20 specs
  	
  	local tmp;
  	foreach ( sensor in devices )
  	{ /*-----  try to read a single sensor -----*/
  	  ++count_readings;
  	  tmp = ow_readSensor( sensor.revid );
  	  if (debug) server.log( format("  [%s] raw read: %i", sensor.revid, tmp) );
  	  /*-------- trap all possible error conditions (not yet finished) -------*/
  	  if ( tmp == 0xFFFF ) // device disconnected/not found
  	  {
  	    sensor.status = "not found";
  	    ++count_devNotFound;
  	    server.log(format("  ERROR: Problem reading device %s.", sensor.revid) );
  	  }
  	  else if ( tmp == 1360 ) // 85.000 °C is the Maxim DS18B20 power-on default. May mean incomplete conversion.
  	  {
  	    sensor.status = "conversion error";
  	    ++count_convertError;
  	    server.log(format("  ERROR: Possible incomplete-conversion of device %s.", sensor.revid) );
  	  }
  	  else // data is valid -> add to external data table
  	  {
  	    sensor.status = "active";
  	    sensor.temp = tmp / 16.0; // convert to °C
        if (debug) server.log( format("  [%s] SUCCESS: %.4f °C",sensor.revid, sensor.temp) );
  	  } /*--- end error condition traps ---*/
    } /*------- end read a sensor -----------*/
  } /*----------- end read all sensors --------*/
}
	
function ow_readSensor(ID)  // read temp of single sensor device (assumes conversion command previously sent)
{                           // ID (string): 64-bit device ID (in reverse byte order as 8x 2 byte ascii hex pairs)
                            // Returns (int): temp in 16ths °C
  local nibble;

  ow_reset();
  onewire.write("b55");
  onewire.write(ID);
  onewire.write("BE");
  onewire.flush();
  imp.sleep(0.1); // **wait for the above echo crap to start or our purge routine will stop at -1 immediately**
  ow_purge(); // clear buffer for subsequent read
  
  onewire.write("FF"); // linkoem echos back LSB (as 2 ascii chars) upon final "F" received
  onewire.flush();
  imp.sleep(0.1); // wait a tad for response (a timeout loop would be better...)
  local LSB_upper = onewire.read(); // gets MSByte of the LSB (as a char)
  local LSB_lower = onewire.read(); // LSByte of the LSB (as a char)
  
  //convert ascii nibbles to 0-15 for each half
  nibble = LSB_lower - '0';
  if (nibble > 9)
    nibble = ((nibble & 0x1f) - 7);
  local LSB = nibble;
  nibble = LSB_upper - '0';
  if (nibble > 9)
    nibble = ((nibble & 0x1f) - 7);
  LSB = LSB + (nibble <<4 ); // top byte shifted into position left 8 bits
  
  //now, repeat for MSByte
  onewire.write("FF");
  onewire.flush();
  imp.sleep(0.1);
  local MSB_upper = onewire.read();
  local MSB_lower = onewire.read();
  
  // convert ascii nibbles to 0-15 for each half
  nibble = MSB_lower - '0';
  if (nibble > 9)
    nibble = ((nibble & 0x1f) - 7);
  local MSB = nibble;
  nibble = MSB_upper - '0';
  if (nibble > 9)
    nibble = ((nibble & 0x1f) - 7);
  MSB = MSB + (nibble <<4 ); // top byte shifted into position left 8 bits
  
  // 2-byte temperature result is LSB + MSB combined (in 16ths of °C)
  return (LSB + (MSB *256) );
}
	
function ow_enum()  // Enumerates devices on 1-wire network.
{										// Returns: custom structured table of all 1-wire devices found
  local found_devices = {};
  local byte, more, devID, ID;
  ++count_enumerations;
  
  if (debug) server.log("enumerating 1-wire bus devices...")

  // any devices present?
  onewire.write(13);
  onewire.flush();
  imp.sleep (0.1);
  ow_purge();
  onewire.write('f');
  onewire.flush();
  imp.sleep (0.1);
  local resp = onewire.read();
  if ( (resp == '+') || (resp == '-')  )
  { //------process found devices------
    do {
      // try reading ID (as ascii hex):
      devID = strip( onewire.readstring().slice(1, 17) ); // grab 16 chars (after comma), test for whitespace
      if ( devID.len() == 16 ) // assume valid ID
      {
        ID = "";
        for ( byte=8; byte>0; --byte )
          ID += devID.slice(byte*2-2,byte*2); // reversed byte order form of Dev ID (used by linkOEM)
        // remap primary slot names from devID to friendly names
        if ( devID == "C700000606FBDE28") devID = "RemoteSensor1";
        else if ( devID == "C9000005AA893728") devID = "BoardSensor1";
        found_devices[devID] <- { revid = ID,
                                  temp = 0xffff, // probationary value
                                  status = "discovered" };
      }
      if ( resp == '+' ) more = true;
      else more = false;
      onewire.write('n');
      onewire.flush();
      imp.sleep (0.1);
      resp = onewire.read();
    } while (more)
  } //-------END found device processing----------
  
  if (found_devices.len() == 0) server.log("[1-Wire bus]: no devices found");
  if (debug) {
    foreach ( index, sensor in found_devices )
      server.log( format("[FOUND]: %s %s %s %i", index, sensor.revid, sensor.status, sensor.temp) );
    server.log("enumeration complete")
  }

  /*----- display error counters -----*/
  if (true) {
    server.log("Counters:");
    server.log(format("  1-wire temperature polls: %i", count_polls));
    server.log(format("  1-wire enumerations:      %i", count_enumerations));
    server.log(format("  Atempted sensor readings: %i", count_readings));
    server.log(format("  Device Not Found errors:  %i", count_devNotFound));
    server.log(format("  Sensor Conversion errors: %i", count_convertError));
  }
  devices.clear();  // keep bus state current
  return (found_devices);
}

function gs_log() //  send sensor data to Grovestreams
{
  imp.wakeup(GS_PERIOD, gs_log);
  if(gs_logging)
  {
    if (devices.len() > 0) // don't bother if no data
    {
      // data wrapper
      local sensordata = { mac = imp.getmacaddress(), sensors = devices };
      server.log("Sending sensor data to Grovestreams Imp Agent");
      agent.send("Grovestreams", sensordata);
    }
  }
}

function xively_log() //  send sensor data to Xively
{
  imp.wakeup(XIVELY_PERIOD, xively_log);
  if ( xively_logging )
  {
    // send only active sensors for logging
    local active = {};
    foreach ( index, sensor in devices )
      if ( sensor.status == "active") active[index] <- sensor;
    if (active.len() > 0) {
      if (debug) server.log("Xively logger: sending "+active.len()+" sensors to log");
      //agent.send("Xively", [devices.C9000005AA893728.temp, devices.C700000606FBDE28.temp]);
      agent.send("Xively", active);
    }
    else server.log("Xively logger: no active sensors to log");
  }
}

function keen_log() //  send sensor data to KeenIO
{
  imp.wakeup(KEEN_PERIOD, keen_log);
  if ( keen_logging )
  {
    // send only active sensors for logging
    local active = {};
    foreach ( index, sensor in devices )
      if ( sensor.status == "active") active[index] <- sensor;
    if (active.len() > 0) {
      if (debug) server.log("keenIO logger: sending "+active.len()+" sensors to log");
        agent.send("keen", active);
    }
    else server.log("keenIO logger: no active sensors to log");
  }
}

/*----------- Agent Handlers -----------------*/
/*----------- Agent Listeners ----------------*/
agent.on("getDevices", function(x) { agent.send("deviceData", devices);} );
agent.on("logging", function(logger) {
  if ( imp in logger && logger.imp.logging == "true" ) server.log("imp logging enabled");
  else server.log("imp logging disabled");
});
agent.on("set_logging", function(logger) {
  if ( xively in logger) {
    if (logging in logger.xively)
      if ( logger.xively.logging == "enable" ) {
        xively_logging = true;
        return ("enable");
      }
      else if ( logger.xively.logging == "disable" ) {
        xively_logging = false;
        return ("disable");
      }
      else return( xively_logging? "enabled" : "disabled");
    else if (period in logger.xively) {
      //period stuff
    }
    
      
      
  }
  
});

// device.send("set_logging", logger[xively] <- { period=req.query.period } );
//             device.on("logging_set", function(v) {

/*----------------------- MAIN program starts here ------------------------------*/

server.log("Build["+BUILD+"] started");

heartbeat();                      // led flasher
devices = ow_enum();              // enumerate sensors
ow_setRes(0);                    // set all sensors to default resolution
startTime = hardware.millis();    // start our time keeper
ow_readall();                     // start temperature reading (main loop)
gs_log();                         // Grovestreams logging
xively_log();                     // Xively logging
keen_log();                     // keen IO logging

