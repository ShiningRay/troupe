import { Stage } from './stage';
import { Appearance } from './appearance';
import Dispatcher from './dispatcher'
import { Reference } from './reference';
import { Message } from './messages';

export class Scenario {
    readonly stage: Stage = Stage.current;
    // router: (msg:Message) => any;
    dispatcher: (msg:Message) => any = Dispatcher;

    static readonly current: Scenario = new Scenario();
    private constructor(){
        Stage.onConnect((stage) => {
            stage.transport.on('data', (msg) => this.dispatcher(<Message>msg))
        });
    }

    sendMessage(message) {
        message.from = this.stage.id;
        var stage = Stage.find(message.to);
        stage.transport.write(message);
    }

    static sendMessage(message) {
        this.current.sendMessage(message)
    }

    static findAppearance(id): Appearance {
        return
    }

    static findReference(id): Reference {
        return
    }
}

