import React from 'react';

import State from '../../stores/State'

import { observable, computed } from 'mobx';
import { Provider, observer } from 'mobx-react'
import { Viewer } from '../Viewer'
import { default as Dropdown } from 'react-simple-dropdown'
import { DropdownTrigger, DropdownContent } from 'react-simple-dropdown'
import { Button } from '../Button';
import { DocumentInfo } from '../DocumentInfo'
import { DocumentRevisionsBrowser } from '../DocumentRevisionsBrowser'

import Request from '../../lib/Request';

import styles from './WindowManager.scss';
import fontAwesome from 'font-awesome/scss/font-awesome.scss'
import dropdownStyles from 'react-simple-dropdown/styles/Dropdown.css'

@observer
export default class WindowManager extends React.Component {

    constructor(props) {
        super(props);

        Request.setBaseUrl(props.baseUrl);
    }

    @observable
    currentMode = this.modes[0];

    @observable
    currentTab = this.tabs[0];

    @observable
    leftPage = 1;

    @observable
    rightPage = 2;

    @observable
    maxViewerHeight = 0;

    @computed
    get host() {
        return this.props.host;
    }

    @computed
    get paneWidth() {
        return Math.floor(this.host.offsetWidth / 2) - 40;
    }

    @computed
    get appState() {
        return new State(this.props.baseUrl);
    }

    @computed
    get sharedContext() {
        return {
            appState: this.appState
        };
    }

    @computed
    get allowImage() {
        return this.props.allowImage;
    }

    get modes() {
        return [
            { name: 'follow-next', title: 'Follow Next' },
            { name: 'follow-current', title: 'Follow Current' },
            { name: 'independent', title: 'Independent Panes' }
        ];
    }

    get tabs() {
        return [
            { name: 'pages', title: 'Pages' },
            { name: 'info', title: 'Document Info' },
            { name: 'versions', title: 'Versions' }
        ];
    }

    @computed
    get modesOptions() {
        return this.modes.map((mode) => {
            return (
              <li key={ `mode-${ mode.name }` }
                  onClick={ () => this.onModeSwitch(mode) }
                  >
                  { this.currentMode.name === mode.name ? `➜ ${mode.title}` : mode.title }
              </li>
            );
        });
    }

    navigatePages() {
        this.currentTab = this.tabs[0];
    }

    navigateInfo() {
        this.currentTab = this.tabs[1];
    }

    navigateVersions() {
        this.currentTab = this.tabs[2];
    }

    onModeSwitch(mode) {
        this.currentMode = mode;

        if(this.currentMode.name === 'follow-next') {
            this.rightPage = this.leftPage + 1;
        }
        else if(this.currentMode.name === 'follow-current') {
            this.rightPage = this.leftPage;
        }
    }

    onLeftPageSwitch(page) {
        this.leftPage = page;

        if(this.currentMode.name === 'follow-next') {
            this.rightPage = page + 1;
        }
        else if(this.currentMode.name === 'follow-current') {
            this.rightPage = page;
        }
    }

    onRightPageSwitch(page) {
        this.rightPage = page;

        if(this.currentMode.name === 'follow-next') {
            this.leftPage = page - 1;
        }
        else if(this.currentMode.name === 'follow-current') {
            this.leftPage = page;
        }
    }

    onViewerRendered(el) {
        this.maxViewerHeight = Math.max(this.maxViewerHeight, el.offsetHeight);
    }

    renderDocumentPanes() {
        return (
            [
              <Viewer width={ this.paneWidth }
                    key={ 1 }
                    page={ this.leftPage }
                    documentId={ this.props.documentId }
                    allowImage={ this.allowImage }
                    onRendered={ this.onViewerRendered.bind(this) }
                    onPageSwitch={ this.onLeftPageSwitch.bind(this) }
                    />,
              <Viewer width={ this.paneWidth }
                      key={ 2 }
                      page={ this.rightPage }
                      documentId={ this.props.documentId }
                      allowImage={ this.allowImage }
                      onRendered={ this.onViewerRendered.bind(this) }
                      onPageSwitch={ this.onRightPageSwitch.bind(this) }
                      />
            ]
        );
    }

    renderPanesOptions() {
        return (
            <div className={ 'corpusbuilder-window-manager-options' } key={ 'pane-options' }>
              <Dropdown>
                <DropdownTrigger>
                  <i className={ 'fa fa-files-o' } aria-hidden="true"></i>
                  &nbsp;
                  Mode: <b>{ this.currentMode.title }</b>
                </DropdownTrigger>
                <DropdownContent>
                  <ul>
                    { this.modesOptions }
                  </ul>
                </DropdownContent>
              </Dropdown>
            </div>
        );
    }

    renderContent() {
        return [
            this.renderDocumentPanes(),
            this.renderPanesOptions()
        ];
    }

    render() {
        return <div className="corpusbuilder-window-manager">
            <Provider {...this.sharedContext}>
                <div>
                    { this.renderContent() }
                </div>
            </Provider>
        </div>
    }
}
