import {Ref, send} from './core';
import {call} from './rpc'
import {EventEmitter} from 'events';

// interact with remote actor
// Maybe this should be a mixin?
export class ActorProxy extends EventEmitter {
	private pid: Ref;
	private channelPrefix: string;

	constructor(pid: Ref) {
		super();
		this.pid = pid;
		// this.channelPrefix = "${this.pid.node}#${this.originClass}#${this.pid.id}";
	}

	send(args: any) {
		return send(this.pid, args);
	}

	call(method: string, args: any[]): PromiseLike<any> {
		return call(this.pid, method, args);
	}
}