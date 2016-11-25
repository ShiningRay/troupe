import * as Promise from 'bluebird';
import Redis = require('ioredis')

export interface IDirectory<KeyType, ValueType> {
    register(id:KeyType, value:ValueType);
    unregister(id:KeyType);
    lookup(id:KeyType):PromiseLike<ValueType>;
}
/*
class LocalActorDirectory implements IDirectory<string, any>{
    private _map:{[id:string]:SimpleActor}
}
*/

interface IDirectoryBackend {
    get(id:string);
    set(id:string, value: any);
    remove(id:string);
}

export class P2PDirectoryBackend implements IDirectoryBackend {
    
} 

export class RedisDirectoryBackend implements IDirectoryBackend{
    private redis
    constructor(redisConfig){
        this.redis = new Redis(redisConfig)
    }
    get(id:string){
        this.redis.get()
    }
    set(id:string, value: any){
        if (condition) {
            
        }
    }
}

export class BaseLocalDirectory<T> implements IDirectory<string, T>{
        private _map:{[id:string]:T}={}
    register(id:string, value:T){
        this._map[id] = value;
    }
    unregister(id:string){
        delete this._map[id]
    }
    lookup(id:string):PromiseLike<T>{
        return Promise.resolve(this._map[id]);
    }    

}

export abstract class BaseRemoteDirectory<T> implements IDirectory<string, T>{
    register(id:string, value:T){
    }
    unregister(id:string){

    }
    lookup(id:string):PromiseLike<T>{
        return
    }
    abstract onChange(cb:(id: string, newValue:T));
    abstract onRemove(cb:(id: string) => any);
}

export abstract class BaseDirectory<T> implements  IDirectory<string, T>{
    
    constructor(private local:BaseLocalDirectory<T>=new BaseLocalDirectory<T>(),
    private remote:BaseRemoteDirectory<T>){
        this.remote.onChange((id, newValue) => {
            this.local.register(id, newValue);
        });
        this.remote.onRemove((id) => this.local.unregister(id))
    }
    register(id:string, value:T){

    }
    unregister(id:string){

    }
    async lookup(id:string):Promise<T>{
        var l = await this.local.lookup(id); 
        if (l) {
            return l;
        }        
        l = await this.remote.lookup(id)
        if (l) {
            this.local.register(id, l);
        }
        return l;        
    }    
}