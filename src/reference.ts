import * as shortid from 'shortid';
import {resolve} from './core';
import {call} from './rpc';
import {Scenario} from './scenario';
import { EventEmitter } from 'events';
import {Stage} from './stage';
import * as Promise from 'bluebird';
import { MessageType, InvocationMessage } from './messages';

interface RequestSpec {
    resolve: Function;
    reject: Function;
    timeout: NodeJS.Timer;
}
/**
 * remote proxy of actor
 * properties starts with `$` is restrict to current scenario
 */
export abstract class Reference extends EventEmitter {
    public $local: boolean = false;
    public $id: any = '';
    public $target: any;
    public readonly $stage: Stage;

    constructor(target){
        super();
        this.$id = shortid.generate();
        this.$target = target;
    }

    private __requests: { [id: number]: RequestSpec } = {};
    private __reqId: number = 0;

    private __send(message:InvocationMessage) {
        Scenario.sendMessage(message);
    }
    public $invoke(method:string, args:any[]) {
        return new Promise((resolve, reject) => {
            var reqId = this.__reqId++;
            this.__send({
                type: MessageType.invocation,
                reqid: reqId, 
                method: method, 
                params: args,
                to: this.$target, 
                from: this.$id
            });
            let t = setTimeout(this.__timeout, 10000, reqId, this) // TODO: move timeout to option
            this.__requests[reqId] = {
                resolve: resolve,
                reject: reject,
                timeout: t
            }
            t.unref();    
        });
    }

    /**
     * handle timeout of request
     */
    private __timeout(reqId: number, self?: Reference) {
        if (!self) {
            self = this;
        }
        var req = self.__requests[reqId];
        if (req) {
            // console.log(Scenario.current(), self.__requests);
            delete self.__requests[reqId];
            req.reject(new Error(`${self} call remote method timeout ${reqId}`));
        } else {
            console.log("Timeout but cannot found corresponding requestspec");
        }
    }

    public $handleResult(message:ResultMessage){
        let req = this.__requests[message.reqid];
        if (req) {
            clearTimeout(req.timeout);
            delete this.__requests[message.reqid];
            req.resolve(message.result);
        } else {
            console.log('cannot find corresponding request', message)
        }
    }

    public $handleError(message:ErrorMessage){
        let req = this.__requests[message.reqid];
        if (req) {
            clearTimeout(req.timeout);
            delete this.__requests[message.reqid];
            return req.reject(message);
        } else {
            console.log('cannot find corresponding request', message)
        }        
    }

    public $handleEvent(message:EventMessage){
        if(Array.isArray(message.data)){
            this.emit(message.name, ...message.data)
        } else {
            this.emit(message.name, message.data)
        }
    }
}