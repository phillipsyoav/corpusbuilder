import Action from '../lib/Action';
import Diff from '../models/Diff';

export default class FetchDocumentDiff extends Action {
    execute(state, selector, params) {
        return state.resolve(selector, () => {
            let url = `${state.baseUrl}/api/documents/${selector.document.id}/${selector.version.identifier}/diff`;

            return this.get(url, { other_version: selector.otherVersion.identifier }).then((raw) => {
                return new Diff(raw);
            });
        });
    }
}

