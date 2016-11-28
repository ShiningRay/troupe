import { MessageType, Message } from './messages';
import { Stage } from './stage';

export default function(message:Message){
    var stage = Stage.find(message.to);
    stage.transport.write(message);
}