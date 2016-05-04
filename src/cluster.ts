import {Ref, Pid, IActor, resolve} from './core';
import {ActorProxy} from './proxy'
import {EventRouter} from './events'
import * as Redis from 'ioredis';

type ActorLike = ActorProxy | IActor;

/**
 * represent the whole cluster system
 * we save nodes information in redis 
 */
export class World {
	static redis:IORedis.Redis = new Redis();
	static findMachine():PromiseLike<Machine>{
		return
	}
	
	static findNode(nodeId:string):PromiseLike<Node>{
		return this.redis.hget('nodes', nodeId).then((data) => {
			var j = JSON.parse(data);
			return new Node(nodeId, j.address);
		}) 
	}
	
	static findActor(ref:Ref):PromiseLike<ActorLike> {
		return this.findNode(ref.node).then((node) => {
			return node.proxy(ref.id);
		});
	}
	
	// static resolve(pid:Ref | Pid | string): ActorLike {
		
	// }
}

/**
 * represent a node js process
 */
export class Node {
	private eventRouter:EventRouter;
	/**
	 * default_state :disconnected
	 * state shutdown
	 * connected
	 * partitioned
	 */
	constructor(public id:string,
	public address:string){
		this.eventRouter = new EventRouter();
	}

	/**
	 * return an actor proxy for interact with the remote actor
	 */
	public proxy(pid:string, ctor?: Function):ActorLike {
		if (this.isCurrent()) {
			return resolve(pid);
		} else {
			return new ActorProxy({node: this.id, id: pid}, this.eventRouter);
		}
		 
	}
	
	isCurrent():boolean{
		// return this == Node.currentNode;
		
	}
	
	static current():Node{
		
	}
}

export class Machine {
	static current():Machine {}
}
