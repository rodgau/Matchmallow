#require "KeenIO.class.nut:1.0.0"

APIKEY <- "removed"; // HTTP handler 'password' for outside device access

/*------- GroveStreams Settings --------*/
GS_API_KEY <- "removed"; //Change This!!! Your GS Organization Secret API Key
GS_COMP_NAME <- "Solar+Test+Sensors" //Optionally change. Your GS Component Name (URL encoded. The "+" indicates spaces)
GS_OFFICE_STREAM_ID <- "sensor01"; //Optionally change. Your GS rssi stream ID
GS_BATHROOM_STREAM_ID <- "sensor02" //Optionally change. Your GS voltage stream ID

/*------- Xively settings-------*/
XIVELY_API_KEY <- "removed";	//Type your Xively API Key
Feed_ID <- "293059339";          		//Type your Feed ID
/*------- END Xively settings-------*/

/*------- keen IO settings-------*/
const KEEN_PROJECT_ID = "53e30cc333e4061149000003";
const KEEN_WRITE_API_KEY = "removed";
/*------- END keen IO settings-------*/

/*------ Globals ---------*/
debug <- true;

/********************BEGIN GROVESTREAMS**************/
GroveStreams <- {}; // this makes a 'namespace'
class GroveStreams.Client { // class to format and send data to Grovestreams service

  constructor() {
  }

  function Put(data){
    local valid=0;
    local url = "https"+"://grovestreams.com/api/feed?compId=" + data.mac;
    url += "&compName=" + GS_COMP_NAME + "+(" + data.mac + ")";
    url += "&api_key=" + GS_API_KEY;
    foreach ( sensor in data.sensors ) // parse for valid sensor data only (saves transaction fees and improves charting)
      if ( sensor.status == "active")
      {  
        ++valid;
        url += "&" + sensor.revid + "=" + sensor.temp;
        if (debug) server.log(format("HTTP Put to Grovestreams: [%s: %.4f]", sensor.revid, sensor.temp) );
      }
    //url += "&compTmplId=template1"; //Uncomment to auto register a new component based on the template with ID=template1
    if ( valid > 0 )
    {
      local headers = { "Connection":"close", "X-Forwarded-For" : data.mac };
      local req = http.put(url, headers, "");
      
      local resp = req.sendsync();
      if(resp.statuscode != 200) {
        server.log("[HTTP ERROR]: GS error sending message: " + resp.body);
        return null;
      }
    }
  } /*-----end Put function -----*/
}
/********************END GROVESTREAMS**************/

/********************BEGIN XIVELY*******************/
//Code written by @beardedinventor modified for use by Joel Wehr
//Modified for use by Rod Gau: Xively.Feed .ToJson table version
Xively <- {};    // this makes a 'namespace'
class Xively.Client {
		ApiKey = null;
		triggers = [];

	constructor(apiKey) {
		this.ApiKey = apiKey;
	}
	
	/*****************************************
	 * method: PUT
	 * IN:
	 *   feed: a XivelyFeed we are pushing to
	 *   ApiKey: Your Xively API Key
	 * OUT:
	 *   HttpResponse object from Xively
	 *   200 and no body is success
	 *****************************************/
	function Put(feed){
		local url = "https://api.xively.com/v2/feeds/" + feed.FeedID + ".json";
		local headers = { "X-ApiKey" : ApiKey, "Content-Type":"application/json", "User-Agent" : "Xively-Imp-Lib/1.0" };
		local request = http.put(url, headers, feed.ToJson());

		return request.sendsync();
	}
	
	/*****************************************
	 * method: GET
	 * IN:
	 *   feed: a XivelyFeed we fulling from
	 *   ApiKey: Your Xively API Key
	 * OUT:
	 *   An updated XivelyFeed object on success
	 *   null on failure
	 *****************************************/
	function Get(feed){
		local url = "https://api.xively.com/v2/feeds/" + feed.FeedID + ".json";
		local headers = { "X-ApiKey" : ApiKey, "User-Agent" : "xively-Imp-Lib/1.0" };
		local request = http.get(url, headers);
		local response = request.sendsync();
		if(response.statuscode != 200) {
			server.log("error sending message: " + response.body);
			return null;
		}
	
		local channel = http.jsondecode(response.body);
		for (local i = 0; i < channel.datastreams.len(); i++)
		{
			for (local j = 0; j < feed.Channels.len(); j++)
			{
				if (channel.datastreams[i].id == feed.Channels[j].id)
				{
					feed.Channels[j].current_value = channel.datastreams[i].current_value;
					break;
				}
			}
		}
	
		return feed;
	}

}

class Xively.Feed{
		FeedID = null;
		Channels = null;

		constructor(feedID, channels)
		{
				this.FeedID = feedID;
				this.Channels = channels;
		}
		
		function GetFeedID() { return FeedID; }

/*  typical ToJson()
    function ToJson()
		{
			local json = "{ \"datastreams\": [";
			for (local i = 0; i < this.Channels.len(); i++)
			{
					json += this.Channels[i].ToJson();
					if (i < this.Channels.len() - 1) json += ",";
			}
			json += "] }";
			return json;
		}
*/		
		// my modded ToJson() for table version of Channels:
		function ToJson()
		{
			local json = "{ \"datastreams\": [";
			foreach ( channel in Channels ) 
			{
					json += channel.ToJson();
					json += ",";
			}
			json = json.slice(0,json.len()-1) + "] }";
			return json;
		}
}

class Xively.Channel {
		id = null;
		current_value = null;
		
		constructor(_id)
		{
				this.id = _id;
		}
		
		function Set(value) { 
			this.current_value = value; 
		}
		
		function Get() { 
			return this.current_value; 
		}
		
		function ToJson() { 
			local json = http.jsonencode({id = this.id, current_value = this.current_value });
				server.log(json);
				return json;
		}
}

// Instantiate our Cloud data service APIs
//
gsclient <- GroveStreams.Client();             // Grovestreams
xivelyclient <- Xively.Client(XIVELY_API_KEY); // Xively
  channels <- {};
  feed <- Xively.Feed(Feed_ID, null);
  /* typical way
    channel1 <- Xively.Channel(Channel1_ID);
    channel2 <- Xively.Channel(Channel2_ID);
    feed <- Xively.Feed(Feed_ID, [channel1, channel2]);
  */
  //********************END XIVELY********************
keen <- KeenIO(KEEN_PROJECT_ID, KEEN_WRITE_API_KEY);

// keenIO data arrival event. Put to keen IO service
device.on("keen", function(devs) {
  if (debug) server.log("keenIO logger: received sensor packet from imp");  
/*eventData <- {
    "location" : {
        "lat" : 37.123,
        "lon" : -122.123
    },
    "temp" : 20.4,
    "humidity" : 36.7
};*/

  // Send an event sycronously
  // "Test 2" is keen's 'Event Collection' name. If non-existant, gets created.
  local result = keen.sendEvent("Test 2", devs);
  server.log(result.statuscode + ": " + result.body);

});



// Grovestreams data arrival event. Put to Grovestreams service
device.on("Grovestreams", function(data) {
    if (debug) server.log("Received sensor data packet from imp (for GS)");
    gsclient.Put(data);
});

// Xively data arrival event. Put to Xively service
device.on("Xively", function(devs) {
  if (debug) server.log("Xively logger: received sensor packet from imp");
  channels.clear();
  foreach (index, sensor in devs) {
    // instantiates a Xively.Channel object and adds it as a slot to the global channels table
    //channels[index] <-Xively.Channel(idmap[sensor.id]); //idmap returns Channel_ID string
    if (sensor.id == "C9000005AA893728") channels[index] <-Xively.Channel("Office"); // spoofed, for now
    else if (sensor.id == "C700000606FBDE28") channels[index] <-Xively.Channel("Heat_Vent"); // spoofed, for now
    else channels[index] <-Xively.Channel("Unknown_Sensor"); // spoofed, for now
    channels[index].Set(sensor.temp);
  }
  //(may not need to use my Set method): feed.Set(channels);
  feed = Xively.Feed(Feed_ID, channels);
	//channel1.Set(v[0]);
	xivelyclient.Put(feed);
});

/**------------------- our http requests handler -----------------------------------------
 * 
 * Base URL:  https://agent.electricimp.com/<your_impDevice_ID>
 * NOTE: if HTTP request path is /json we assume JSON data encoding. URL data ignored.
 * Otherwise, standard URL query assumed with entry points as follows:
 *  ?apikey=APIKEY_HERE   required
 *  ?show=all             return all sensors (comma-delimited)
 *  ?show=disconnected    return all sensors currently reporting as not found/disconnected  (comma-delimited)
 *  ...
 *  /xyz?key1=value1      (eample: /xyz path entry point with key1/value1 key/value pair)
*/
function requestHandler(req, resp) {
  try {
    // DEBUG LOGGINGg
    if (debug) {
      server.log("http method [" + req.method + "]");
      server.log("http path[" + req.path + "]");
      server.log("http query [" + req.query + "]");
      server.log("http body[" + req.body + "]");
      server.log("http headers[" + req.headers + "]");
    }
    local path = req.path.tolower();
    
    if ( path == "/json" || path == "/json/" ) {
    /*---------- begin JSON body parsing -------------*/
      local data = http.jsondecode(req.body);
      if (debug) server.log("json received: " + req.body);
      if ("apikey" in data && data.apikey == APIKEY) {
        server.log("valid access request from api key: "+ data.apikey );
        if ("setting" in data) {
          server.log(" setting in data");
          if ("logging" in data.setting) {
            server.log("logging in data.setting");
            if( set_logging(data.setting.logging) == "invalid")
              resp.send(400, "INVALID LOGGING REQUEST");
            else  resp.send(200,"OK");
          }
        }
        else if ("button1" in data) {
          if (debug) server.log("Command received: show all" );
          device.send("getDevices", 1);
          device.on("deviceData", function(devs) {
            local body = http.jsonencode(devs);
            //EXAMPLE (works for Pitchfork): local body = "{ \"status\" : { \"button1\" : \"" + 9.01199 + "\" }}";
            server.log(body);
            resp.send(200,body);
          });
        }
        else if ("button2" in data) {
          if (debug) server.log("Command received: show disconnected" );
          device.send("getDevices", 1);
          device.on("deviceData", function(devs) {
            local notfound={};
            foreach ( index, sensor in devs )
              if ( sensor.status == "not found") notfound[index] <- sensor;
            server.log(http.jsonencode(notfound));
            resp.send(200,http.jsonencode(notfound));
          });
        }
        else resp.send(400, "BAD REQUEST");
      }
      else {
        if ( "apikey" in data )
          server.log("invalid access request from api key: "+data.apikey);
        else
          server.log("Request missing api key");
        local json = "{ \"status\" : { \"auth\" : \"no\" }}";
        resp.send(401, json);
      }
    }
    /*---------- end JSON body parsing -------------*/
    else {
      /*--------------- begin regular url-based query parsing ----------*/
      if (debug) server.log("http query received: [" + req.query + "]");
      if ("apikey" in req.query && req.query.apikey == APIKEY) {
        server.log("valid access request from api-key: "+ req.query.apikey);
        if (req.path == "/devices" || req.path == "/devices/") {
          if ("show" in req.query)
          {
            if (req.query.show == "disconnected" ) // return all sensors currently reporting as not found
            {
              if (debug) server.log("Command received: show=disconnected" );
              device.send("getDevices", 1);
              device.on("deviceData", function(devs) {
                local notfound="";
                foreach ( sensor in devs )
                  if ( sensor.status == "not found") notfound = notfound + sensor.id + ",";
                server.log(notfound);
                resp.send(200, notfound); // send comma-delimited data back as our response
              });
            }
            else if (req.query.show == "all" ) // return all sensors discovered on 1-wire bus
            {
              if (debug) server.log("Command received: show=all" );
              device.send("getDevices", 1);
              device.on("deviceData", function(devs) {
                local result="";
                foreach ( sensor in devs ) result = result + sensor.id + ",";
                if (debug) server.log(result);
                resp.send(200, result); // send comma-delimited data back as our response
              });
            }
            else resp.send(400, "Valid show params: all, disconnected");
          }
          else resp.send(400, "Valid devices commands: show");
        }
        else /********* Xively ***********/
        if (req.path == "/xively" || req.path == "/xively/")
        {
          if ( "logging" in req.query )
          {
            if (debug) server.log("Command received: Xively logging: "+req.query.logging );
            local logger = {};
            device.send("set_logging", logger["xively"] <- { logging=req.query.logging } );
            device.on("logging_set", function(v) {
              if ( v == req.query.logging ) server.log("Success. Xively logging "+ v +"d");
              else server.log("Failure. Xively logging still "+ v );
              resp.send(200, "OK");
            });
          }
          else if ( "period" in req.query )
          {
            if (debug) server.log("Command received: Xively period: "+req.query.period );
            local logger = {};
            device.send("set_logging", logger[xively] <- { period=req.query.period } );
            device.on("logging_set", function(v) {
              if ( v == req.query.period ) server.log("Success. Xively logging period: "+ v);
              else server.log("Failure: Xively logging period: "+ v);
              resp.send(200, "OK");
            });
          }
          else resp.send(400, "Invalid Xively query. Valid params: logging=enable/disable and period=x");
        } /********** END Xively *********/
        else /********* Grovestreams ***********/
        if (req.path == "/gs" || req.path == "/gs/")
        {
          if ( "logging" in req.query )
          {
            if (debug) server.log("Command received: Grovestreams logging: "+req.query.logging );
            local logger = {};
            device.send("set_logging", logger[gs] <- { logging=req.query.logging } );
            device.on("logging_set", function(v) {
              if ( v == req.query.logging ) server.log("Success. Grovestreams logging "+ v +"d");
              else server.log("Failure. Grovestreams logging still "+ v );
              resp.send(200, "OK");
            });
          }
          else if ( "period" in req.query )
          {
            if (debug) server.log("Command received: Grovestreams period: "+req.query.period );
            local logger = {};
            device.send("set_logging", logger[gs] <- { period=req.query.period } );
            device.on("logging_set", function(v) {
              if ( v == req.query.period ) server.log("Success. Grovestreams logging period: "+ v);
              else server.log("Failure: Grovestreams logging period: "+ v);
              resp.send(200, "OK");
            });
          }
          else resp.send(400, "Invalid Grovestreams query. Valid params: logging=enable/disable and period=x");
        } /********** END GS *********/ 
        
        // no valid queries in request whatsoever
        else resp.send(400, "BAD REQUEST");
      }
      else {
        if ( "apikey" in req.query )
          server.log("invalid access request from api key: "+ req.query.apikey);
        else server.log("Request missing api key");
        local json = "{ \"status\" : { \"auth\" : \"no\" }}";
        resp.send(401, json);
      }
    } /*---------- END url-query processing ---------*/
  } catch (ex)
    {
      resp.send(500, "Internal Server Error: " + ex);
      server.log("goober 500 error");
    }
} /*-------------- end http request handler ----------------*/

function set_logging(logger) {  // request device set logging type
  server.log("now in set_logging function");
  server.log(logger);
  if ("xively" in logger)
    if ("enabled" in logger.xively) {
      if (logger.xively.enabled == "true") xively_logging = true;
    }
    if ("period" in logger.xively) server.log("xively logging period requested: "+ logger.xively.period );
      
  // switch (logger) {
  //   case ("xively" in logger):
  //     server.log("xively logging requested")
  //     break;
  //   case ("gs" in logger):
  //     server.log("gs logging requested")
  //     break;
  //   case ("imp" in logger):
  //     server.log("imp debug logging requested")
  //     break;
  //   default:
  //     server.log("invalid logging type requested")
  //     break;
  // }
}

/*----------- Device handlers ----------------*/
//
// Programming Note:
//    The device.on handler example below must be defined **inline** within the above
//    http requesthandler code above in order for it to behave syncronously, as intended.
//    Otherwise we don't get our devices table back from the imp until some lines of code later, time-wise.
//
// (MUST BE INLINE): device.on("deviceData", function(devs) { //devs data processing here; } );
//
/*-------------------------------------------*/

server.log("Registering HTTP handler...")
http.onrequest(requestHandler); // register the HTTP handler
server.log("Waiting for HTTP requests...")

