import {Ref, send} from './core';
import {call} from './rpc'
import {EventEmitter} from 'events';
import {EventRouter} from './events';

// interact with remote actor
// Maybe this should be a mixin?
export class ActorProxy extends EventEmitter {
	public pid: Ref;

	constructor(pid: Ref, private eventRouter:EventRouter) {
		super();
		this.pid = pid;
	}

	send(args: any) {
		return send(this.pid, args);
	}
    
    /**
     * 
     */
    on(eventName:string, listener:Function){
        // super.on(eventName, listener);
        this.eventRouter.subscribe(this.pid, eventName, listener);
        return this;
    }

	call(method: string, args: any[]): PromiseLike<any> {
		return call(this.pid, method, args);
	}
}