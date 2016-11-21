import {Actor, ActorReference} from './actor'
import {Stage} from './stage'
import {Message, MessageType, InvocationMessage, ResultMessage, ErrorMessage, EventMessage} from './messages'
/**
 * address
 */
class AppearanceLocation {
    stage: Stage;
}

/**
 * 
 */
function serializedExecutor(message){
    this.processing = true;
    
    if(!message){
        if (this.mailbox.length == 0) {
            this.processing = false;
            return
        }
        message = this.mailbox.shift();
    }
        
    // execute one message
    return this.run(message).then(() => {
        if (this.mailbox.length == 0) {
            // no remaining messages, stop processing
            this.processing = false;
        } else {
            // push job to event loop
            setImmediate(() => this.execute());
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
    private mailbox:Message[];
    private processing:boolean = false;
    private reference: ActorReference;
    private execute:(msg:Message) => any;

    constructor(private actor: Actor, reentrant:boolean=false){
        if (reentrant) {
            this.execute = reentrantExecutor
        } else {
            this.execute = serializedExecutor
        }
    }

    onmessage(message:Message){
        if(this.processing)
            this.mailbox.push(message);
        else
            this.execute(message);
    }

    run(message:Message):PromiseLike<any>{
        switch(message.type){
            case MessageType.invocation:
            break
            default:
        }
    }
}
