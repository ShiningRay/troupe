import {EventEmitter} from 'events'
import {Duplex, Transform} from 'stream'
import Redis = require('ioredis')


/**
 * 
 */
abstract class RemoteReference<T> extends EventEmitter {
    interfaceName: string;
    interfaceClass: new (...args:any[]) => T;
    scenario: Scenario;
} 

interface Transport extends NodeJS.ReadWriteStream {

}

interface AppearanceLocation {
    stage: Stage;
    
}

interface ActorDirectory {
    register( address: AppearanceLocation,  singleActivation: boolean,  hopCount:number);
    unregister( address: AppearanceLocation, cause: string, hopCount: number)
    lookup()
}

/**
 * LRU-style, will deactivate inactive actors perodicly 
 */
interface LocalActorDirectory {

}

interface RemoteActorDirectory {

}

/**
 * interner will use weak reference to cache some actor references
 * acts as cache
 */
interface Interner {

}

class JSONMessageEncoder extends Transform {
    constructor(){
        super({ objectMode: true });
    }
    transform(chunk, encoding, cb){

    }
} 

class RedisTransport extends Duplex implements Transport {
    private emitter: IORedis.Redis;
    // private receiver: IORedis.Redis;
    // private channelListeners: { [channel: string]: Function[] } = {};
    // private patternListeners: { [pattern: string]: Function[] } = {};
    private mailbox: IORedis.Redis;
    private nodeId: string;

    constructor(nodeId){
        super({objectMode: true});
        this.nodeId = nodeId;
        this.emitter = new Redis();
        this.mailbox = new Redis();
        // this.receiver = new Redis();
        // this.receiver.on('pmessage', this.handlePatternEvent.bind(this));
        // this.receiver.on('message', this.handleEvent.bind(this));        
    }

}

class Theater {
    /**
     * ip address of current machine
     */
    address: string;
    /**
     * indicate if current stage located in the theater
     */
    local: boolean;
    /**
     * indicate if current process is the curator process
     */
    current: boolean;
}

class Stage {
    pid:number;
    port: number;
    /**
     * on the same machine with current process
     */
  local:boolean;
  /**
   * is current process?
   */
  current:boolean;
  /**
   * the message transport with current process
   */
  transport: Transport;
  static current: Stage;
}

/**
 * router to send message to correct actor; 
 */
interface MessageRouter {
    sendTo(actor:RemoteReference, messageType:MessageType):this;
    send(message:Message):this;
}

/**
 * receive incoming messages and findout correct actor to respond it
 */
interface MessageDispatcher {
    on(type:'message', callback: (message:Message) => any):this;
}

interface Message {
    type: MessageType;
}

enum MessageType {
    normal,
    event,
    system
}

class Scenario {
    stage: Stage;
    router: MessageRouter
    dispatcher: MessageDispatcher; 
    static readonly current:Scenario = new Scenario();
}

/**
 * master logics 
 * represent the master process on each machine  
 * expose some api for manage process on the same machine 
 */
interface TheaterCurator {
    /**
     * start cluster on current machine;
     */
    open():Theater;
    /**
     * exit all the process on current machine
     */
    shutdown();
}

/**
 * expose some api for management purpose 
 */
interface StageDirector {
    /**
     * close current stage and exit
     */
    close();
}

/**
 * 
 */
function serializedExecutor(message){
    this.processing = true;
    if(!message)
        message = this.mailbox.shift();
    this.run(message).then(() => {
        if (this.mailbox.length == 0) {
            this.processing = false;
        } else {
            setImmediate(this.execute.bind(this));
        }
    }).catch((err) => {
        this.actor.onerror(err);
    });
}

function reentrantExecutor(message){
    return this.run(message);
}
/**
 * Active actor in system
 * contains some runtime information
 */
class Appearance {
    private mailbox:any[];
    private processing:boolean = false;
    private actor: Actor;
    private execute:Function;

    onmessage(message:any){
        if(this.processing)
            this.mailbox.push(message);
        else
            this.execute(message);
    }

    run(message:any):PromiseLike<any>{
        return
    }
}

/**
 * an Actor implementation which ensure thread safety
 * one message by one message
 */
class AbstractActor {

}

/**
 * Actor decorator
 * @Actor('Room')
 * class RoomActor implements Room{
 * }
 */
function Actor(classId:string){
    return function(cls:Function){
        
    }
}
// import lodash from 'lodash';
var referenceClassTemplate = `
    class 
`