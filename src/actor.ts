import {stop} from './core'
import {BasicActor} from './basic_actor'
/**
 * an Actor implementation which ensure thread safety
 * one message by one message 
 */
class Actor extends BasicActor {
    constructor(){
        super();
    }
    private mailbox:any[];
    private processing:boolean = false;
    
    onmessage(message:any){
        this.mailbox.push(message);
        if (!this.processing) {
            this.__processMessage(this);
        }
    }
    
    __processMessage(self:Actor){
        self.processing = true;
        var message = self.mailbox.shift();
        self.run(message).then(() => {
            if (self.mailbox.length == 0) {
                self.processing = false;
            } else {
                process.nextTick(this.__processMessage, this);
            }
        }).catch((err) => {
            self.onerror(err);
        });
    }
    
    run(message:any):PromiseLike<any>{
        return super.onmessage(message);
    }
}