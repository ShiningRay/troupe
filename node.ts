import Redis = require('ioredis');
import {IActor, Actor, Ref, Pid} from './index'
import {EventEmitter} from 'events';
import * as Promise from 'bluebird';
var subscriber:IORedis.Redis;

/**
 * router outside actor's event to proxy
 */
export class EventRouter {
	private eventChannel: IORedis.Redis;
    private channelPrefix: string;
	
	constructor(){
		this.eventChannel = new Redis();	
		this.channelPrefix = `${this.processId}#`;
        this.eventChannel.psubscribe(`${this.channelPrefix}*`)
        this.eventChannel.on('pmessage', this.handleEvent.bind(this));
	}
	
    handleEvent(channel:string, message:string){
        let [processId, id, eventName] = channel.split(/[#\/.]/);
		
        let actor = ActorProxy.resolve(processId, id);
        if(actor){
			actor.emit(eventName, JSON.parse(message));
        } else {
            console.log('cannot find that actor with id', id);
        }
    }
}

// interact with remote actor
// Maybe this should be a mixin?
export class ActorProxy extends EventEmitter {
	private pid:Ref;
	private channelPrefix:string;
	
	constructor(pid:Ref){
		super();
		this.pid = pid;
		// this.channelPrefix = "${this.pid.node}#${this.originClass}#${this.pid.id}";
	}
	
	send(args:any){
		return Actor.send(this.pid, args);
	}
	
	call(method:string, args:any[]):PromiseLike<any>{
		return Actor.call(this.pid, method, args);
	}
}

/**
 * represent a machine who runs many nodejs process
 */
export class Machine {
	private _addresses:number[];
	
	/**
	 * get current machine on which current process runs
	 */
	public static current(){
		// if not register then register
	}
}

/**
 * represent a node js process
 */
export class Node {
	/**
	 * default_state :disconnected
	 * state shutdown
	 * connected
	 * partitioned
	 */
	
	private _id:string;
	private _address:string;
	public get id():string{
		return this._id;
	}

	/**
	 * return an actor proxy for interact with the remote actor
	 */
	public proxy(pid:string):ActorProxy {
		return
	}
	
	/**
	 * find node from the cluster
	 */
	static find(nodeId:string):Node{
		return 
	}
}