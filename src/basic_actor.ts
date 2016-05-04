import {Ref, Pid, IActor, start, send, stop} from './core';
import {call} from './rpc';
import {publish} from './events';
import {Node} from './cluster';
import {RequestSpec} from './rpc';

// Base Actor Model 
// Publish Events to outside proxy via redis channel
// TODO: move Actor behavior to separated class and make Actor a namespace
export class BasicActor implements IActor {
    //   private _id; // the unique id
    //   private _dispatcher;
    //   private _registry;
    /**
     * actor identifier, unique in one node
     */
    private _pid: string;
    private state: any = {};
    private __reqId: number = 0;
    private __requests: { [id: number]: RequestSpec } = {};
    private __send(pid: Pid, args: any) {
        send(pid, args);
    }

    /**
     * send a remote procedure call to remote actor 
     * @param pid, Actor's pid
     */
    private __call(pid: Pid, method: string, args: any[]): PromiseLike<any> {
        console.log(Node.current(), this.pid, 'call', pid, method, args);
        return new Promise((resolve, reject) => {
            var reqId = this.__reqId++;
            this.__send(pid, { type: 'call', reqid: reqId, method: method, args: args, from: { node: Ray.node, id: this.pid } });
            this.__requests[reqId] = {
                resolve: resolve,
                reject: reject,
                timeout: setTimeout(this.__timeout, 10000, reqId, this) // TODO: move timeout to option                
            }
        });
    }

    // handle timout for rpc
    private __timeout(reqId: number, self?: BasicActor) {
        if (!self) {
            self = this;
        }
        var req = self.__requests[reqId];
        if (req) {
            console.log(Node.current(), self.__requests);
            delete self.__requests[reqId];
            req.reject(new Error(`${self.pid} call remote method timeout ${reqId}`));
        } else {
            console.log("Timeout but cannot found corresponding requestspec");
        }
    }

    onstart() {
        this.state = {};
    }

    /**
     * handle messages, 
     * TODO: move each message handler to own function 
     */
    onmessage(message: any) {
        var req: RequestSpec;

        // handle remote invokation
        switch (message.type) {
            // I'm being invoked
            case 'call':
                if (typeof this[message.method] != 'function') {
                    return send(message.from, { type: 'error', error: "no such method", reqid: message.reqid });
                }
                try {
                    var result = this[message.method].apply(this, message.args);
                } catch (err) {
                    return send(message.from, { type: 'error', error: err, reqid: message.reqid });
                }

                // if result is a promise
                if (typeof result.then == 'function') {
                    result.then(
                        (data) =>
                            send(message.from, { type: 'result', result: result, reqid: message.reqid })
                    ).catch(
                        (err) =>
                            send(message.from, { type: 'error', error: err, reqid: message.reqid }));
                } else {
                    send(message.from, { type: 'result', result: result, reqid: message.reqid });
                }
                break;
            // I'm telling a result for previous my own invokation to remote actor
            case 'result':
                req = this.__requests[message.reqid];
                if (req) {
                    clearTimeout(req.timeout as number);
                    delete this.__requests[message.reqid];
                    req.resolve(message.result);
                } else {
                    console.log('cannot find corresponding request')
                }
                break;
            case 'error':
                req = this.__requests[message.reqid];
                if (req) {
                    clearTimeout(req.timeout as number);
                    delete this.__requests[message.reqid];
                    req.reject(message.error);
                } else {
                    console.log('cannot find corresponding request')
                }
                break;
            default:
                break;
        }
    }

    run(message: any): PromiseLike<any> {
        return
    }

    /**
     * handle some errors
     */
    onerror(error: any) {
        this.onexit(error);
        stop(this);
    }

    /**
     * the actor is exiting, handle cleanup job here
     */
    onexit(reason: any) {
        console.log(reason);
    }
    /**
     * broadcast events to remote subscribers
     * because in javascript, developers love to do event listening, 
     */
    emit(eventName: string, ...args: any[]) {
        publish(this, eventName, args);
    }
    // this should be @sealed and @readonly after initialized
    public get pid(): string {
        return this._pid;
    }
}

