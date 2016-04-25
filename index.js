'use strict';

var Redis = require('ioredis')
var EventEmitter = require('events')
var shortid = require('shortid')

// Base Actor Model 
class Actor {
//   private _id; // the unique id
//   private _dispatcher;
//   private _registry;

  constructor () {
    // register self to the registry
    // dispatcher will find this object from registry
	Actor.register(this);
  }
  
  onmessage (message){
      // do something when message come
  }
  
  pid () {
	  return this._pid;
  }
  
  static register(name, object){
      if(typeof object == "undefined"){
          object = name;
          name = shortid.generate();
      }
      this._actors[name] = object;
      object._pid = [this.dispatcher.processId, name];
  }
  static resolve(name){
      return this._actors[name];
  }
  static send(pid, args){
      this.dispatcher.send(pid, args);
  }
}

Actor._actors = {};


class Dispatcher extends EventEmitter{
    constructor(processId){
        super();
        Actor.dispatcher = this;
        this.redis = new Redis();
        this.processId = processId;
        this.mailbox = new Mailbox(new Redis(), this);
        this.mailbox.start();
        this.redis.sadd("nodes", this.processId);
    }
    
    dispose(){
        this.redis.sdel("nodes", this.processId);
        delete this.mailbox;
    }
    
    process(pid, message) {
        if(pid instanceof Array){
            pid = pid[1];
        }
        var actor = Actor.resolve(pid);
        if(actor){
            actor.onmessage(message);
        } else {
            console.log('cannot find that actor', pid);
        }
    }
    
    send(pid, message){
        if(pid instanceof Array){
            if(pid[0] == this.processId){
                return this.process(pid[1], message);
            }
            this.redis.lpush(pid[0], JSON.stringify([pid[1], message]));
        } else {
            this.process(pid, message);
        }
    }
}

class Mailbox {
    constructor(redis, dispatcher){
        this.redis = redis;
        this.dispatcher = dispatcher;
    }
    
    start(){
        this.redis.blpop(this.dispatcher.processId, 0).then( (reply) => {
            var args = JSON.parse(reply[1]);
            console.log('receive from queue', reply);
            this.dispatcher.process(args[0], args[1]);
            process.nextTick(this.start.bind(this));
        }).catch( (err) => {
            console.log('pop from queue error', err);
            process.nextTick(this.start.bind(this));
        });
    }
}

var processId = shortid.generate();
console.log('process id', processId)

var dispatcher = new Dispatcher(processId);


class User extends Actor {
    constructor(){
        super();
        this.redis = new Redis();
        this.redis.sadd("users", JSON.stringify(this.pid()));
        setTimeout(this.hello.bind(this), 5000);
    }
    
    hello() {
        console.log('sending ping');
        
        this.redis.smembers("users").then((users) => {
            users.forEach((u) => {
                var pid = JSON.parse(u);
                if(pid[1] != this._pid[1]){
                    Actor.send(pid, {from: this.pid(), content: "ping"});
                }
            });
        });
    }
    
    onmessage(message){
        console.log('receiving', message);
        
            Actor.send(message.from, {from: this.pid(), content: "pong"});
    }
}
var user = new User();

process.on('uncaughtException', (err) => {
    console.log(err);
    dispatcher.dispose();
});
