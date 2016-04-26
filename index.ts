import {sealed} from './lib/sealed';
import Redis = require('ioredis')
var EventEmitter = require('events')
import shortid = require('shortid')

type Ref = [string, string];
interface IActor {
    pid: Ref;
    onmessage(message:any);
    emit(eventName:string, ...args:any[]);
    onexit();
}


type IActorCtor = (new (...args: any[]) => IActor);

// Base Actor Model 
class Actor implements IActor{
//   private _id; // the unique id
//   private _dispatcher;
//   private _registry;
    private _pid:string;

  
  onmessage (message:any){
      // do something when message come
  }
  
  onexit(){
      
  }
  
  emit(eventName:string, ...args:any[]){
      
  }
  // @sealed
  public get pid ():string {
	  return this._pid;
  }
  
  static dispatcher: Dispatcher;
  static _actors:{[name:string]: IActor}= {};
  
  static register(name:string, object:IActor){
    //   if(typeof object == "undefined"){
    //       object = name;
    //       name = shortid.generate();
    //   }
      this._actors[name] = object;
      object._pid = [this.dispatcher.processId, name];
  }
  
  static resolve(name:string){
      return this._actors[name];
  }
  
  static send(pid, args){
      this.dispatcher.send(pid, args);
  }
  
  static start(ctor:IActorCtor, args?:any[], name?:string){
    // register self to the registry
    // dispatcher will find this object from registry
	// Actor.register(this);
    var actor = new ctor(...args);
    actor._pid = [this.dispatcher.processId, name];
    return actor;
  }
  
  static init(cb?:(...args:any[])=>any){
      this.dispatcher = new Dispatcher(shortid.generate());
      process.on('beforExit', (code) => {
        this.dispatcher.dispose();
      });
      if (cb) {
          cb(this.dispatcher);
      }
  }
}

class Dispatcher extends EventEmitter{
    private redis:IORedis.Redis;
    public processId:string;
    private mailbox:IORedis.Redis;
    
    constructor(directory:Directory){
        super();
        this.redis = new Redis();
        this.processId = directory.register();
        this.mailbox = new Redis();
        this.receive();
    }
    
    receive(self?:Dispatcher){
        if(!self){
            self = this;
        }
        
        self.mailbox.blpop(self.processId, 0).then( (reply) => {
            var args = JSON.parse(reply[1]);
            console.log('receive from queue', reply);
            self.process(args[0], args[1]);
            process.nextTick(self.receive, self);
        }).catch( (err) => {
            console.log('pop from queue error', err);
            process.nextTick(self.receive, self);
        });
    }    
    
    dispose(){
        this.redis.sdel("nodes", this.processId);
        delete this.mailbox;
    }
    
    process(pid:Ref, message:any) {
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
    
    send(pid:Ref, message:any){
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

class User extends Actor {
    private redis:IORedis.Redis;
    constructor(){
        super();
        this.redis = new Redis();
        this.redis.sadd("users", JSON.stringify(this.pid()));
        setTimeout(this.hello.bind(this), 5000);
    }
    
    hello() {
        console.log('sending ping');
        var self = this.pid();
        this.redis.smembers("users").then((users) => {
            users.forEach((u) => {
                var pid = JSON.parse(u);
                if(pid[1] != self[1]){
                    Actor.send(pid, {from: self, content: "ping"});
                }
            });
        });
    }
    
    onmessage(message){
        console.log('receiving', message);
        
        Actor.send(message.from, {from: this.pid(), content: "pong"});
    }
}


process.on('uncaughtException', (err) => {
    console.log(err);
});

Actor.init(function () {
    var user = Actor.start(User);
});