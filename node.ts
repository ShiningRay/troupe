var subscriber:IORedis.Redis;
type Ref = [string, string];

// maybe we can use different messages
export class ActorProxy {
	private pid:Ref;
	private originClass:string;
	private channelPrefix:string;
	
	constructor(){
		this.channelPrefix = "${this.pid[0]}#${this.originClass}#${this.pid[1]}";
	}

	on(eventName, ...args:any[]){
		subscriber.subscribe(`${this.channelPrefix}.${eventName}`);
	}

	dispose(){
		subscriber.unsubscribe(this.channelPrefix);
	}
}

export class Node {
	private _id:string;
	private _address:string;
	public get id():string{
		return this._id;
	}

	public get address():string {
		return this._address
	}

	public proxy(pid:string) {

	}
}